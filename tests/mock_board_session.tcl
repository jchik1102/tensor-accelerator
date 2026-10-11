set launch [lindex $argv 0]
set test_dir [file dirname $launch]
set memory [dict create 0 0x54413031 4 0 12 0 20 0 32 255 36 0x48455831]
proc record {text} {
    global test_dir
    set f [open [file join $test_dir traffic.log] a];puts $f $text;close $f
}
proc fault {} {
    global test_dir
    set path [file join $test_dir fault]
    if {![file exists $path]} {return ""}
    set f [open $path];set value [string trim [read $f]];close $f;return $value
}
proc get_service_paths {type} {return /mock/master}
proc claim_service {args} {record CLAIM;return mock_claim}
proc close_service {args} {record CLOSE}
proc getword {address} {
    global memory
    if {[dict exists $memory $address]} {return [dict get $memory $address]}
    return 0
}
proc signed {word bits} {
    set mask [expr {(1 << $bits)-1}];set word [expr {$word & $mask}]
    return [expr {$word & (1 << ($bits-1)) ? $word-(1 << $bits) : $word}]
}
proc compute {} {
    global memory
    for {set layer 0} {$layer < [getword 12]} {incr layer} {
        set descriptor {}
        for {set i 0} {$i < 8} {incr i} {lappend descriptor [getword [expr {256+32*$layer+4*$i}]]}
        lassign $descriptor m k n src dst wb pb relu
        for {set col 0} {$col < $n} {incr col} {
            set acc [signed [getword [expr {4096+12*($pb+$col)}]] 32]
            for {set j 0} {$j < $k} {incr j} {
                incr acc [expr {[signed [getword [expr {65536+4*($src+$j)}]] 8]*[signed [getword [expr {131072+4*($wb+$col*$k+$j)}]] 8]}]
            }
            if {$relu && $acc < 0} {set acc 0}
            set acc [expr {max(-128,min(127,$acc))}]
            dict set memory [expr {65536+4*($dst+$col)}] [expr {$acc & 0xffffffff}]
        }
    }
    dict set memory 4 2;dict set memory 20 228537
}
proc master_write_32 {handle address words} {
    global memory
    set address [expr {$address}]
    record "W $address $words"
    if {$address==8} {
        switch [lindex $words 0] {
            4 {dict set memory 4 0;dict set memory 12 0}
            2 {dict set memory 4 0}
            1 {if {[fault] eq "stall"} {dict set memory 4 1} else {compute}}
        }
        return
    }
    foreach word $words {dict set memory $address $word;incr address 4}
}
proc master_read_32 {handle address count} {
    set address [expr {$address}];record "R $address $count"
    set words {}
    for {set i 0} {$i < $count} {incr i} {
        set a [expr {$address+4*$i}]
        if {$a==8} {error "Command register is write-only"}
        set word [getword $a]
        if {[fault] eq "wrong_id" && $a==0} {set word 42}
        if {[fault] eq "old_image" && $a==36} {set word 0}
        if {[fault] eq "display_readback" && $a==32} {set word 254}
        if {[fault] eq "reset" && $a==12} {set word 0}
        if {[fault] eq "corrupt" && $a==65544} {incr word}
        lappend words $word
    }
    if {[fault] eq "short" && $address==65544} {set words [lrange $words 1 end]}
    return $words
}
source $launch
