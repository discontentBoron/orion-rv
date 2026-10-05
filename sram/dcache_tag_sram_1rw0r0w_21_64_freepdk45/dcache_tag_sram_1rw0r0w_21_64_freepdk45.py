# OpenRAM config: dcache_tag_sram  (64 words x 21 bits, 1RW)
word_size = 21
num_words = 64

num_rw_ports = 1
num_r_ports  = 0
num_w_ports  = 0
# Technology name
tech_name = "freepdk45"

# Process corner specifications
nominal_corner_only = False
use_specified_corners = [
    ("SS", 0.95, 125)
]
process_corners = ["SS"]
supply_voltages = [0.95]
temperatures = [125]

# Enable VDD and VSs routing
route_supplies = "ring"
check_lvsdrc = True
# Parallel runs
num_threads = 4
num_sim_threads = 4

analytical_delay = False
load_scales = [1, 8, 16]
slew_scales = [0.5, 2, 8, 16]

# Outputs
output_name = "dcache_tag_sram_{0}rw{1}r{2}w_{3}_{4}_{5}".format(
    num_rw_ports,
    num_r_ports,
    num_w_ports,
    word_size,
    num_words,
    tech_name
)
output_path = "../orion-rv/sram/{}".format(output_name)
