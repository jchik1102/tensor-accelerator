if {![info exists env(TA_MASTER_PATH)] || ![info exists env(TA_BOARD_IMAGE_CONFIRMED)] || $env(TA_BOARD_IMAGE_CONFIRMED) ne "TA01"} {error "Select a confirmed TA01 master first"}
set h [claim_service master $env(TA_MASTER_PATH) hex_qualification]
proc expect {h address expected} {
    set actual [lindex [master_read_32 $h $address 1] 0]
    if {$actual != $expected} {error "REGISTER_MISMATCH addr=$address expected=$expected actual=$actual"}
}
set recognized 0
try {
    expect $h 0 0x54413031
    expect $h 0x24 0x48455831
    expect $h 4 0
    set recognized 1
    expect $h 0x20 255
    puts HEX_RESET_DASH_REGISTER_PASS
    foreach digit {0 1 2 3 4 5 6 7 8 9} {
        master_write_32 $h 0x20 [list $digit]
        expect $h 0x20 $digit
        puts "HEX_DIGIT_REGISTER_PASS $digit"
    }
    master_write_32 $h 0x20 {10}
    expect $h 0x20 255
    puts HEX_INVALID_DASH_REGISTER_PASS
    master_write_32 $h 0x20 {8}
    master_write_32 $h 8 {4}
    expect $h 0x20 255
    expect $h 4 0
    puts HEX_SOFT_RESET_REGISTER_PASS
} finally {
    try {
        if {$recognized} {master_write_32 $h 0x20 {255}}
    } finally {close_service master $h}
}
puts PHYSICAL_HEX_QUALIFICATION_COMPLETE
