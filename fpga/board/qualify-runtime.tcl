if {![info exists env(TA_MASTER_PATH)] || ![info exists env(TA_BOARD_IMAGE_CONFIRMED)] || $env(TA_BOARD_IMAGE_CONFIRMED) ne "TA01"} {
    puts "PENDING: select the confirmed TA01 image and explicit master path."
    puts "MASTER_PATHS=[get_service_paths master]"
    return
}
set path $env(TA_MASTER_PATH)
if {[lsearch -exact [get_service_paths master] $path] < 0} {error "Selected master path is not available"}
set handle [claim_service master $path tensor_accelerator_qualification]
set saved {}
set scratch 0x17f00
try {
    set identity [lindex [master_read_32 $handle 0 1] 0]
    if {$identity != 0x54413031} {error "Wrong image ID; no writes performed"}
    set status [lindex [master_read_32 $handle 4 1] 0]
    if {$status & 1} {error "Accelerator busy; no writes performed"}
    set saved [master_read_32 $handle $scratch 64]
    set started [clock milliseconds]
    set transferred 0
    foreach pattern {zero ones alternating seeded} {
        set words {};set seed 20261008
        for {set i 0} {$i < 64} {incr i} {
            switch $pattern {
                zero {set value 0}
                ones {set value 255}
                alternating {set value [expr {$i % 2 ? 0x55 : 0xaa}]}
                seeded {set seed [expr {(1664525*$seed+1013904223)&0xffffffff}];set value [expr {($seed>>24)&255}]}
            }
            lappend words $value
        }
        master_write_32 $handle $scratch $words
        set actual [master_read_32 $handle $scratch 64]
        if {[llength $actual] != 64} {error "Short block read"}
        for {set i 0} {$i < 64} {incr i} {
            if {([lindex $actual $i]&255) != [lindex $words $i]} {error "Readback mismatch $pattern index=$i"}
        }
        master_write_32 $handle $scratch {0x80}
        if {([lindex [master_read_32 $handle $scratch 1] 0]&0xffffffff) != 0xffffff80} {error "Sign extension mismatch"}
        incr transferred 520
        puts "TRANSFER_PATTERN_PASS $pattern"
    }
    puts "TRANSFER_MEASUREMENT bus_bytes=$transferred elapsed_ms=[expr {[clock milliseconds]-$started}] seed=20261008"
    puts "TRANSFER_READBACK_PASS image=TA01 master=$path scratch=$scratch words=64"
} finally {
    try {
        if {[llength $saved] == 64} {master_write_32 $handle $scratch $saved}
    } finally {close_service master $handle}
}
