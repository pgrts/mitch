import os

# ------------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------------
OUTPUT_DIR = "."
FILENAME_FMT = "grid_{:03d}_thick.smd"
TEXTURE_NAME = "fs_meter"

# Grid Dimensions (Matches your successful grid_074)
COLS = 10
ROWS = 10
BLOCK_W = 6.0
BLOCK_H = 4.0
DEPTH = 2.0  # (Y = 0 to Y = -2)

# Start Position
# X: -30 to +30 (Center 0)
START_X = -30.0 
START_Z = 0.0

Y_FRONT = 0.0
Y_BACK = -2.0  # Explicitly -2.0 based on depth

# ------------------------------------------------------------------
# HELPERS
# ------------------------------------------------------------------
SMD_HEADER = """version 1
nodes
0 "root" -1
end
skeleton
time 0
0 0 0 0 0 0 0
end
triangles
"""
SMD_FOOTER = "end\n"

# Vertex Line Format
# P x y z nx ny nz u v
V_FMT = "0 {:0.6f} {:0.6f} {:0.6f} {:0.6f} {:0.6f} {:0.6f} {:0.6f} {:0.6f}\n"

def get_solid_block(x_bl, z_bl):
    """
    Returns the 12 triangles for a solid cube at (x, z)
    with corrected winding for external visibility.
    """
    x0 = x_bl
    x1 = x_bl + BLOCK_W
    z0 = z_bl
    z1 = z_bl + BLOCK_H
    y0 = Y_FRONT
    y1 = Y_BACK

    # 8 Corners
    # Front (Y=0)
    f_bl = (x0, y0, z0)
    f_tl = (x0, y0, z1)
    f_tr = (x1, y0, z1)
    f_br = (x1, y0, z0)
    
    # Back (Y=-2)
    b_bl = (x0, y1, z0)
    b_tl = (x0, y1, z1)
    b_tr = (x1, y1, z1)
    b_br = (x1, y1, z0)

    tris = []

    def add_tri(v1, v2, v3, nx, ny, nz):
        t = f"{TEXTURE_NAME}\n"
        t += V_FMT.format(v1[0], v1[1], v1[2], nx, ny, nz, 0, 0)
        t += V_FMT.format(v2[0], v2[1], v2[2], nx, ny, nz, 0, 1)
        t += V_FMT.format(v3[0], v3[1], v3[2], nx, ny, nz, 1, 1)
        tris.append(t)

    # -------------------------------------------------------
    # 1. FRONT FACE (+Y)
    # Winding: BL -> TL -> TR (Counter-Clockwise)
    # Normal: (0, 1, 0)
    add_tri(f_bl, f_tl, f_tr, 0, 1, 0)
    add_tri(f_bl, f_tr, f_br, 0, 1, 0)

    # -------------------------------------------------------
    # 2. BACK FACE (-Y)
    # Winding: BL -> TR -> TL (Clockwise relative to front, CCW relative to back view)
    # Normal: (0, -1, 0)
    add_tri(b_bl, b_tr, b_tl, 0, -1, 0)
    add_tri(b_bl, b_br, b_tr, 0, -1, 0)

    # -------------------------------------------------------
    # 3. LEFT FACE (-X)
    # Normal: (-1, 0, 0)
    # Vertices: Front-BL, Back-BL, Back-TL, Front-TL
    # Winding: Front-BL -> Back-BL -> Front-TL
    add_tri(f_bl, b_bl, f_tl, -1, 0, 0)
    add_tri(b_bl, b_tl, f_tl, -1, 0, 0)

    # -------------------------------------------------------
    # 4. RIGHT FACE (+X)
    # Normal: (1, 0, 0)
    # Vertices: Front-BR, Back-BR, Back-TR, Front-TR
    # Winding: Front-BR -> Front-TR -> Back-BR
    add_tri(f_br, f_tr, b_br, 1, 0, 0)
    add_tri(f_tr, b_tr, b_br, 1, 0, 0)

    # -------------------------------------------------------
    # 5. TOP FACE (+Z)
    # Normal: (0, 0, 1)
    # Winding: Front-TL -> Front-TR -> Back-TR
    add_tri(f_tl, f_tr, b_tr, 0, 0, 1)
    add_tri(f_tl, b_tr, b_tl, 0, 0, 1)

    # -------------------------------------------------------
    # 6. BOTTOM FACE (-Z)
    # Normal: (0, 0, -1)
    # Winding: Front-BL -> Back-BL -> Back-BR (Looking from bottom)
    add_tri(f_bl, b_bl, b_br, 0, 0, -1)
    add_tri(f_bl, b_br, f_br, 0, 0, -1)

    return "".join(tris)

def main():
    # 1. Calculate Block Positions (0 to 100)
    # Row-major order (fill row 0, then row 1...)
    blocks = []
    for r in range(ROWS):
        for c in range(COLS):
            x = START_X + (c * BLOCK_W)
            z = START_Z + (r * BLOCK_H)
            blocks.append((x, z))
    
    total_blocks = len(blocks)
    print(f"Generating geometry for {total_blocks} blocks...")

    # 2. Generate Files
    for count in range(total_blocks + 1):
        filename = FILENAME_FMT.format(count)
        path = os.path.join(OUTPUT_DIR, filename)
        
        with open(path, 'w') as f:
            f.write(SMD_HEADER)
            
            # Accumulate geometry for blocks 0 to count-1
            for i in range(count):
                bx, bz = blocks[i]
                f.write(get_solid_block(bx, bz))
                
            f.write(SMD_FOOTER)
            
        if count % 25 == 0:
            print(f"Generated {filename}")

    print("Success! 101 solid SMD files generated.")

if __name__ == "__main__":
    main()