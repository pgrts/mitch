import os
import math
from collections import defaultdict

# --- Configuration ---
THICKNESS = 1.0
# We offset along -Y (Standard Source engine "depth" for walls usually on XZ plane)
# If your grid is oriented differently, change this tuple (e.g. 0, 0, -1)
OFFSET_DIR = (0.0, -1.0, 0.0) 

IN_GLOB_PREFIX = "grid_"
IN_EXT = ".smd"

OUT_DOUBLE_DIR = "out_double"
OUT_SLAB_DIR = "out_slab"

ROUND_KEY = 6  # Precision for welding vertices to detect edges

# --- Vector Math Helpers ---
def v_add(a, b): return (a[0]+b[0], a[1]+b[1], a[2]+b[2])
def v_sub(a, b): return (a[0]-b[0], a[1]-b[1], a[2]-b[2])
def v_mul(a, s): return (a[0]*s, a[1]*s, a[2]*s)
def v_len(a): return math.sqrt(a[0]*a[0] + a[1]*a[1] + a[2]*a[2])

def v_norm(a):
    L = v_len(a)
    if L <= 1e-9: return (0.0, 0.0, 0.0)
    return (a[0]/L, a[1]/L, a[2]/L)

def v_cross(a, b):
    return (a[1]*b[2]-a[2]*b[1],
            a[2]*b[0]-a[0]*b[2],
            a[0]*b[1]-a[1]*b[0])

def fmt_f(x): return f"{x:.6f}"

# Key for vertex welding/edge detection
def key_pos(p):
    return (round(p[0], ROUND_KEY), round(p[1], ROUND_KEY), round(p[2], ROUND_KEY))

class Vert:
    __slots__ = ("bone", "pos", "norm", "suffix")
    def __init__(self, bone, pos, norm, suffix):
        self.bone = bone
        self.pos = pos
        self.norm = norm
        self.suffix = suffix  # includes UV + weights/links

def parse_vertex(line: str):
    parts = line.strip().split()
    if len(parts) < 9: return None
    try:
        bone = int(parts[0])
        pos = (float(parts[1]), float(parts[2]), float(parts[3]))
        norm = (float(parts[4]), float(parts[5]), float(parts[6]))
        suffix = " ".join(parts[7:])
        return Vert(bone, pos, norm, suffix)
    except Exception:
        return None

def write_vert(out, v: Vert):
    out.write(
        f"{v.bone} {fmt_f(v.pos[0])} {fmt_f(v.pos[1])} {fmt_f(v.pos[2])} "
        f"{fmt_f(v.norm[0])} {fmt_f(v.norm[1])} {fmt_f(v.norm[2])} {v.suffix}\n"
    )

def make_back_vert(v: Vert, offset_vec):
    # Create a vertex pushed back by offset, with flipped normal
    return Vert(
        v.bone,
        v_add(v.pos, offset_vec),
        (-v.norm[0], -v.norm[1], -v.norm[2]),
        v.suffix
    )

def process_one_file(in_path: str, out_path: str, make_slab: bool):
    with open(in_path, "r", encoding="utf-8", errors="ignore") as f:
        lines = f.readlines()

    # Find triangle block
    tri_start = None
    tri_end = None
    for i, line in enumerate(lines):
        if line.strip() == "triangles": tri_start = i; break
    
    if tri_start is None: return # Invalid SMD

    for i in range(tri_start+1, len(lines)):
        if lines[i].strip() == "end": tri_end = i; break

    if tri_end is None: return # Invalid SMD

    header_lines = lines[:tri_start+1]
    trailer_lines = lines[tri_end:]

    # Parse triangles
    triangles = [] # list of (material, [v0,v1,v2])
    tri_verts = []
    cur_mat = "default"

    for line in lines[tri_start+1:tri_end]:
        s = line.strip()
        if not s: continue
        
        # Material check (non-numeric first char)
        if not (s[0].isdigit() or s[0] == '-'):
            cur_mat = s
            continue

        v = parse_vertex(line)
        if v:
            tri_verts.append(v)
            if len(tri_verts) == 3:
                triangles.append((cur_mat, tri_verts))
                tri_verts = []

    # Prepare logic
    off_dir = v_norm(OFFSET_DIR)
    offset_vec = v_mul(off_dir, THICKNESS)

    # If making slab, detect boundary edges
    edge_counts = defaultdict(int)
    edge_data = {} # key -> (mat, vA, vB)

    if make_slab:
        for mat, tv in triangles:
            ps = [key_pos(v.pos) for v in tv]
            # Edges: 0-1, 1-2, 2-0
            for i, j in [(0,1), (1,2), (2,0)]:
                k = tuple(sorted((ps[i], ps[j]))) # undirected edge key
                edge_counts[k] += 1
                edge_data.setdefault(k, (mat, tv[i], tv[j]))

    # Write Output
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as out:
        for l in header_lines: out.write(l)

        for mat, tv in triangles:
            out.write(mat + "\n")
            
            # 1. Front Face (Original)
            for v in tv: write_vert(out, v)

            # 2. Back Face (Offset & Flipped & Reversed Winding)
            out.write(mat + "\n")
            # Reverse 0,1,2 -> 2,1,0
            back_verts = [make_back_vert(v, offset_vec) for v in reversed(tv)]
            for v in back_verts: write_vert(out, v)

        # 3. Slab Side Walls (Optional)
        if make_slab:
            for k, count in edge_counts.items():
                if count == 1: # It's a boundary edge!
                    mat, vA, vB = edge_data[k]
                    
                    # Quad vertices
                    # Front: A -> B
                    # Back:  B' -> A'
                    # We need two triangles to fill A->B->B'->A'
                    
                    # Original Front Verts
                    fA = vA
                    fB = vB
                    # Offset Back Verts
                    bA = make_back_vert(vA, offset_vec)
                    bB = make_back_vert(vB, offset_vec)

                    # Calculate side normal (cross product of edge and offset)
                    edge_vec = v_sub(fB.pos, fA.pos)
                    side_n = v_norm(v_cross(edge_vec, offset_vec))
                    
                    # Function to re-normal vertex for flat shading on side
                    def side_v(v, n): return Vert(v.bone, v.pos, n, v.suffix)

                    sA_f = side_v(fA, side_n)
                    sB_f = side_v(fB, side_n)
                    sA_b = side_v(bA, side_n)
                    sB_b = side_v(bB, side_n)

                    out.write(mat + "\n")
                    # Tri 1: A_front -> B_front -> B_back
                    write_vert(out, sA_f)
                    write_vert(out, sB_f)
                    write_vert(out, sB_b)

                    out.write(mat + "\n")
                    # Tri 2: A_front -> B_back -> A_back
                    write_vert(out, sA_f)
                    write_vert(out, sB_b)
                    write_vert(out, sA_b)

        for l in trailer_lines: out.write(l)

def main():
    here = os.getcwd()
    inputs = [f for f in os.listdir(here) if f.startswith(IN_GLOB_PREFIX) and f.endswith(IN_EXT)]
    inputs.sort()

    if not inputs:
        print(f"No files found starting with '{IN_GLOB_PREFIX}' and ending with '{IN_EXT}'")
        return

    print(f"Found {len(inputs)} files. Processing...")

    for fn in inputs:
        in_path = os.path.join(here, fn)
        base_name = fn[:-4] # strip .smd
        
        # Output paths
        path_double = os.path.join(here, OUT_DOUBLE_DIR, f"{base_name}_double.smd")
        path_slab   = os.path.join(here, OUT_SLAB_DIR,   f"{base_name}_thick.smd")

        process_one_file(in_path, path_double, make_slab=False)
        process_one_file(in_path, path_slab,   make_slab=True)
        
        print(f"Generated: {path_double} & {path_slab}")

if __name__ == "__main__":
    main()