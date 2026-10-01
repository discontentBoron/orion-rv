# icache_tag_sram: 128 words x 20 bits, 1RW

word_size = 20
num_words = 128

num_rw_ports = 1
num_r_ports  = 0
num_w_ports  = 0

tech_name = "freepdk45"

# Match NangateOpenCellLibrary_slow_ccs.lib
nominal_corner_only = False

process_corners = ["SS"]
supply_voltages = [0.95]
temperatures = [125]
analytical_delay = False
use_specified_corners = [
    ("SS", 0.95, 125)
]

# Physical integration
route_supplies = "ring"
check_lvsdrc = True

num_threads = 4
num_sim_threads = 4

# Characterization grid
load_scales = [1, 8, 16]
slew_scales = [0.5, 2, 8, 16]

output_name = "icache_tag_sram_{0}rw{1}r{2}w_{3}_{4}_{5}".format(
    num_rw_ports,
    num_r_ports,
    num_w_ports,
    word_size,
    num_words,
    tech_name
)

output_path = "../orion-rv/sram/{}".format(output_name)
