# OpenRAM config: dcache_data_sram  (512 words x 32 bits, 1RW)
word_size = 32
num_words = 512
write_size = 8   # byte write mask -> wmask0[3:0]
num_rw_ports = 1
num_r_ports  = 0
num_w_ports  = 0

tech_name = "freepdk45"
nominal_corner_only = False
use_specified_corners = [
    ("SS", 0.95, 125)
]
only_use_config_corners = True


route_supplies = False
check_lvsdrc = True
analytical_delay = False
process_corners = ["SS"]
supply_voltages = [0.95]
temperatures = [125]

load_scales = [0.5, 1, 4]
slew_scales = [0.5, 1]

output_name = "dcache_data_sram_{0}rw{1}r{2}w_{3}_{4}_{5}".format(
    num_rw_ports,
    num_r_ports,
    num_w_ports,
    word_size,
    num_words,
    tech_name
)

output_path = "../orion-rv/sram/{}".format(output_name)