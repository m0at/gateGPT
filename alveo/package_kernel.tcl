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

create_project -force kernel_pack $tmp_proj -part $part
add_files -norecurse [glob [file join $rtl_dir *.v]]
add_files -norecurse [glob [file join $gen_dir *.v]]
set_property top krnl_namegen [current_fileset]
# bake the farm size into the kernel
set_property generic [list NUM_GEN=$num_gen] [current_fileset]
update_compile_order -fileset sources_1

ipx::package_project -root_dir $packaged -vendor m0at.com -library kernel \
    -taxonomy /KernelIP -import_files -set_current false
ipx::unload_core $packaged/component.xml
ipx::edit_ip_in_project -upgrade true -name tmp_edit_project \
    -directory $packaged $packaged/component.xml

set core [ipx::current_core]
set_property core_revision 1 $core
set_property sdx_kernel true $core
set_property sdx_kernel_type rtl $core

# Vitis kernels expose no user IP parameters; bake NUM_GEN via the fileset generic above.
foreach up [ipx::get_user_parameters -of_objects $core] {
    ipx::remove_user_parameter [get_property NAME $up] $core
}

# tie the AXI interfaces to the kernel clock (ap_rst_n auto-associates with ap_clk)
ipx::associate_bus_interfaces -busif m_axi_gmem    -clock ap_clk $core
ipx::associate_bus_interfaces -busif s_axi_control -clock ap_clk $core

set_property xpm_libraries {XPM_CDC XPM_MEMORY XPM_FIFO} $core
ipx::create_xgui_files $core
ipx::update_checksums $core
ipx::check_integrity -kernel $core
ipx::save_core $core
close_project -delete

package_xo -force -xo_path $xo_out -kernel_name krnl_namegen \
    -ip_directory $packaged -kernel_xml $kernel_xml

if { [file exists $xo_out] } {
    puts "package_kernel: wrote $xo_out (NUM_GEN=$num_gen, part=$part)"
} else {
    puts "ERROR: package_xo did not produce $xo_out"
    exit 1
}
