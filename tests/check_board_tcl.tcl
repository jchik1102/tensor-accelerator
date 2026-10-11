set root [file normalize [file join [file dirname [info script]] ..]]
set memory [dict create 0 0x54413031 4 0]
for {set i 0} {$i<64} {incr i} {dict set memory [expr {0x17f00+4*$i}] [expr {$i&255}]}
set baseline $memory
set closed 0
proc get_service_paths {type} {return {mock}}
proc claim_service {type path owner} {return mock}
proc close_service {type handle} {set ::closed 1}
proc master_read_32 {handle address count} {
    set words {}
    for {set i 0} {$i<$count} {incr i} {
        set at [expr {$address+4*$i}]
        if {![dict exists $::memory $at]} {error "Mock read outside permitted region"}
        set value [dict get $::memory $at]
        if {$at>=0x17f00 && $value>=128} {set value [expr {$value|0xffffff00}]}
        lappend words $value
    }
    return $words
}
proc master_write_32 {handle address words} {
    set address [expr {$address+0}]
    foreach value $words {
        if {$address<0x17f00 || $address>0x17ffc || $address%4} {error "Mock unsafe write"}
        dict set ::memory $address [expr {$value&255}]
        incr address 4
    }
}
set env(TA_MASTER_PATH) mock
set env(TA_BOARD_IMAGE_CONFIRMED) TA01
source [file join $root fpga board qualify-runtime.tcl]
if {!$closed || $memory ne $baseline} {error "Scratch restoration/service close failed"}
dict set memory 0 0
set closed 0
if {![catch {source [file join $root fpga board qualify-runtime.tcl]} reason]} {error "Wrong ID was accepted"}
if {![string match "Wrong image ID*" $reason] || !$closed} {error "Wrong-ID failure was not closed correctly"}
foreach file [list [file join $root artifacts board inference.tcl] [file join $root fpga board qualify-runtime.tcl] [file join $root fpga board qualify-hex.tcl]] {
    set f [open $file r];set body [read $f];close $f
    if {![info complete $body]} {error "Incomplete Tcl source $file"}
}
puts "OFFLINE_TCL_PASS scratch patterns/restoration, wrong-ID guard, source completeness; no hardware accessed"
