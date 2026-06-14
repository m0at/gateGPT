# Package the krnl_namegen RTL into a Vitis kernel object (krnl_namegen.xo).
# Follows the standard Vitis RTL-kernel packaging flow (ipx::package_project -> package_xo).
#
#   vivado -mode batch -source alveo/package_kernel.tcl -tclargs <part> <num_gen> <xo_out>
# e.g.
#   vivado -mode batch -source alveo/package_kernel.tcl -tclargs \
#          xcu200-fsgd2104-2-e 32 ./build/krnl_namegen.xo
#
# Run alveo/scripts/prep_sources.py first (creates alveo/gen_src/*.v).

if { $::argc < 3 } {
    puts "ERROR: usage: package_kernel.tcl <part> <num_gen> <xo_out>"
    exit 1
}
set part     [lindex $::argv 0]
set num_gen  [lindex $::argv 1]
set xo_out   [lindex $::argv 2]

set alveo_dir  [file normalize [file dirname [info script]]]
set rtl_dir    [file join $alveo_dir rtl]
set gen_dir    [file join $alveo_dir gen_src]
set kernel_xml [file join $alveo_dir krnl_namegen.xml]
set work_dir   [file join $alveo_dir build _pack]
set packaged   [file join $work_dir packaged_kernel]
set tmp_proj   [file join $work_dir tmp_kernel_pack]

file mkdir [file dirname $xo_out]
if { [file exists $work_dir] } { file delete -force $work_dir }
file mkdir $work_dir
if { [file exists $xo_out] }   { file delete -force $xo_out }

if { ![file isdirectory $gen_dir] } {
    puts "ERROR: $gen_dir missing -- run: python3 alveo/scripts/prep_sources.py"
    exit 1
}
if { ![file exists $kernel_xml] } {
    puts "ERROR: kernel xml missing: $kernel_xml"
    exit 1
}

# Collect RTL. gen_src/ holds the self-contained core (incl. name_generator) that
# namegen_farm.v instantiates; rtl/ holds the kernel wrapper, control slave, writer,
# farm and FIFO. Fail loudly if either set is empty (no silent under-packaging).
set rtl_files [glob -nocomplain [file join $rtl_dir *.v]]
set gen_files [glob -nocomplain [file join $gen_dir *.v]]
if { [llength $rtl_files] == 0 } { puts "ERROR: no RTL in $rtl_dir"; exit 1 }
if { [llength $gen_files] == 0 } { puts "ERROR: no generated core in $gen_dir -- run prep_sources.py"; exit 1 }

create_project -force kernel_pack $tmp_proj -part $part
add_files -norecurse $rtl_files
add_files -norecurse $gen_files
set_property top krnl_namegen [current_fileset]
# Bake the farm size into the kernel via a top-level generic. Vitis RTL kernels expose
# NO user IP parameters, so this is how a build-time constant reaches the RTL.
set_property generic [list NUM_GEN=$num_gen] [current_fileset]
update_compile_order -fileset sources_1

# Sanity: confirm the chosen top actually elaborates with this part before packaging,
# so a missing/renamed module fails here (clear message) rather than deep inside package_xo.
if { [catch { synth_design -rtl -name rtl_elab_check -top krnl_namegen -part $part \
                 -generic NUM_GEN=$num_gen } emsg] } {
    puts "ERROR: RTL elaboration of krnl_namegen failed (NUM_GEN=$num_gen):"
    puts $emsg
    exit 1
}

ipx::package_project -root_dir $packaged -vendor m0at.com -library kernel \
    -taxonomy /KernelIP -import_files -set_current false
ipx::unload_core $packaged/component.xml
ipx::edit_ip_in_project -upgrade true -name tmp_edit_project \
    -directory $packaged $packaged/component.xml

set core [ipx::current_core]
set_property core_revision 1 $core
# Mark as an SDx/Vitis RTL kernel so v++ recognizes it.
set_property sdx_kernel      true $core
set_property sdx_kernel_type rtl  $core
# U200 spans 3 SLRs of UltraScale+; allow all virtexuplus parts so the kernel is not
# rejected on the target platform.
set_property supported_families {virtexuplus Production} $core

# Vitis kernels expose no user IP parameters; bake NUM_GEN via the fileset generic above.
foreach up [ipx::get_user_parameters -of_objects $core] {
    ipx::remove_user_parameter [get_property NAME $up] $core
}
# Also strip the HDL parameter from the packaged IP so XRT/v++ does not surface NUM_GEN
# as a settable arg (it is a compile-time constant, not a kernel argument).
foreach hp [ipx::get_hdl_parameters -of_objects $core] {
    catch { ipx::remove_hdl_parameter [get_property NAME $hp] $core }
}

# Clock/reset association (canonical Vitis RTL-kernel requirement):
#  - tie both AXI interfaces to the single kernel clock ap_clk;
#  - explicitly associate ap_rst_n as that clock's reset with ACTIVE_LOW polarity,
#    rather than relying on name-based auto-association.
ipx::associate_bus_interfaces -busif m_axi_gmem    -clock ap_clk $core
ipx::associate_bus_interfaces -busif s_axi_control -clock ap_clk $core
ipx::associate_bus_interfaces -busif s_axi_control -reset ap_rst_n -clock ap_clk $core
set rst_if [ipx::get_bus_interfaces ap_rst_n -of_objects $core]
if { $rst_if ne "" } {
    set pol [ipx::get_bus_parameters POLARITY -of_objects $rst_if]
    if { $pol eq "" } { set pol [ipx::add_bus_parameter POLARITY $rst_if] }
    set_property value ACTIVE_LOW $pol
}

set_property xpm_libraries {XPM_CDC XPM_MEMORY XPM_FIFO} $core
ipx::create_xgui_files $core
ipx::update_checksums $core
ipx::check_integrity -kernel $core
ipx::save_core $core
close_project -delete

# package_xo binds the kernel.xml (arg offsets / control protocol) to the packaged IP.
# The -kernel_name MUST match <kernel name="..."> in the xml and the top module.
package_xo -force -xo_path $xo_out -kernel_name krnl_namegen \
    -ip_directory $packaged -kernel_xml $kernel_xml

if { [file exists $xo_out] } {
    puts "package_kernel: wrote $xo_out (NUM_GEN=$num_gen, part=$part)"
} else {
    puts "ERROR: package_xo did not produce $xo_out"
    exit 1
}
