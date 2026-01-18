import os

def generate_grid_smd(index, output_dir="out_slab1"):
    if not os.path.exists(output_dir):
        os.makedirs(output_dir)
        
    filename = os.path.join(output_dir, f"grid_{index:03d}_thick.smd")
    with open(filename, "w") as f:
        f.write("version 1\nnodes\n0 \"root\" -1\nend\nskeleton\ntime 0\n0 0 0 0 0 0 0\nend\ntriangles\n")
        
        # Grid parameters
        cols, rows = 10, 10
        block_w, block_h = 4.0, 6.0
        start_x = -20.0 # Centered: -20 to 20
        depth = -1.0    # 1 unit deep
        
        for i in range(index):
            row = i // cols
            col = i % cols
            x1, x2 = start_x + (col * block_w), start_x + ((col + 1) * block_w)
            z1, z2 = row * block_h, (row + 1) * block_h
            
            # Front Face
            f.write(f"fs_meter\n0 {x1} 0.0 {z1} 0 1 0 0 1\n0 {x2} 0.0 {z1} 0 1 0 1 1\n0 {x2} 0.0 {z2} 0 1 0 1 0\n")
            f.write(f"fs_meter\n0 {x1} 0.0 {z1} 0 1 0 0 1\n0 {x2} 0.0 {z2} 0 1 0 1 0\n0 {x1} 0.0 {z2} 0 1 0 0 0\n")
            # Back Face
            f.write(f"fs_meter\n0 {x1} {depth} {z1} 0 -1 0 0 1\n0 {x1} {depth} {z2} 0 -1 0 0 0\n0 {x2} {depth} {z2} 0 -1 0 1 0\n")
            f.write(f"fs_meter\n0 {x1} {depth} {z1} 0 -1 0 0 1\n0 {x2} {depth} {z2} 0 -1 0 1 0\n0 {x2} {depth} {z1} 0 -1 0 1 1\n")
        f.write("end\n")

for i in range(101):
    generate_grid_smd(i)