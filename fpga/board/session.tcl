proc ta_publish {name text} {
    global ta_dir
    set target [file join $ta_dir $name]
    set f [open "$target.tmp" w]
    try {puts $f $text} finally {close $f}
    file rename -force "$target.tmp" $target
}
proc ta_check_host {} {
    global ta_dir
    if {[file exists [file join $ta_dir stop]] ||
        [clock seconds]-[file mtime [file join $ta_dir heartbeat]] > 15} {
        error "Host session stopped; no automatic retry"
    }
}
proc ta_read {address count} {
    global ta_h
    set words [master_read_32 $ta_h $address $count]
    if {[llength $words] != $count} {error "Short read at $address"}
    return [lmap word $words {expr {$word & 0xffffffff}}]
}
proc ta_guard {check_model} {
    global ta_outputs ta_descriptors
    set regs [ta_read 0 2]
    if {[lindex $regs 0] != 0x54413031} {error "Wrong TA01 identity; no inference writes performed"}
    if {[lindex $regs 1] & 1} {error "Accelerator busy"}
    if {$check_model && ([lindex $regs 1] & 4)} {error "Accelerator error status"}
    if {$check_model && ([lindex [ta_read 12 1] 0] != [llength $ta_outputs] ||
        [ta_read 0x100 [llength $ta_descriptors]] ne $ta_descriptors)} {
        error "Model configuration lost or changed; restart and reload required"
    }
}
proc ta_display {data} {
    global ta_seq ta_displayed ta_ticket ta_h
    if {[llength $data] != 3} {error "Invalid display request"}
    lassign $data ticket seq digit
    foreach x $data {if {![string is integer -strict $x]} {error "Invalid display field"}}
    if {$ticket != $ta_ticket+1 || $seq != $ta_seq ||
        !(($digit >= 0 && $digit <= 9) || $digit == 255)} {error "Invalid display sequence/digit"}
    ta_check_host
    ta_guard 1
    if {$digit != 255 && ($seq == 0 || $ta_displayed == $seq || [lindex [ta_read 4 1] 0] != 2)} {
        error "No uncommitted completed inference"
    }
    master_write_32 $ta_h 0x20 [list $digit]
    if {[lindex [ta_read 0x20 1] 0] != $digit} {error "HEX0 register readback mismatch"}
    set ta_ticket $ticket
    if {$digit != 255} {set ta_displayed $seq}
    ta_publish "display-$ticket.txt" "DISPLAY $ticket $seq $digit"
}
proc ta_infer {seq inputs} {
    global ta_h ta_input_count ta_outputs
    if {[llength $inputs] != $ta_input_count} {error "Wrong input size"}
    foreach value $inputs {
        if {![string is integer -strict $value] || $value < -128 || $value > 127} {error "Invalid INT8 input"}
    }
    set t0 [clock milliseconds]
    ta_check_host
    ta_guard 1
    set t1 [clock milliseconds]
    master_write_32 $ta_h 8 {2}
    for {set i 0} {$i < $ta_input_count} {incr i 256} {
        ta_check_host
        set words [lmap x [lrange $inputs $i [expr {$i+255}]] {expr {$x & 0xffffffff}}]
        master_write_32 $ta_h [expr {0x10000+4*$i}] $words
    }
    ta_check_host
    set t2 [clock milliseconds]
    master_write_32 $ta_h 8 {1}
    set deadline [expr {$t2+10000}]
    while {1} {
        ta_check_host
        set status [lindex [ta_read 4 1] 0]
        if {!($status & 1)} {break}
        if {[clock milliseconds] >= $deadline} {error "Inference timeout; result uncertain"}
        after 1
    }
    if {$status != 2} {error "Inference failed with status $status"}
    set t3 [clock milliseconds]
    set cycles [lindex [ta_read 20 1] 0]
    set layers {};set i 0
    foreach output $ta_outputs {
        lassign $output address count
        lappend layers "LAYER $i [ta_read $address $count]"
        incr i
    }
    set t4 [clock milliseconds]
    return "OK $seq\nMETRICS $cycles [expr {$t1-$t0}] [expr {$t2-$t1}] [expr {$t3-$t2}] [expr {$t4-$t3}]\n[join $layers \n]\nEND $seq"
}

set ta_h ""
set ta_ready 0
set ta_seq 0
set ta_ticket 0
set ta_displayed 0
set ta_hex_recognized 0
try {
    ta_check_host
    if {[lsearch -exact [get_service_paths master] $ta_master] < 0} {error "Selected master unavailable"}
    set ta_h [claim_service master $ta_master tensor_accelerator_drawing]
    ta_guard 0
    if {[lindex [ta_read 0x24 1] 0] != 0x48455831} {error "HEX1 image required; load the new SOF"}
    set ta_hex_recognized 1
    master_write_32 $ta_h 0x20 {255}
    set load_start [clock milliseconds]
    master_write_32 $ta_h 8 {4}
    set f [open [file join $ta_dir model.txt] r]
    try {
        while {[gets $f line] >= 0} {
            ta_check_host
            master_write_32 $ta_h [lindex $line 0] [lrange $line 1 end]
        }
    } finally {close $f}
    ta_guard 1
    ta_publish ready.txt "READY [expr {[clock milliseconds]-$load_start}]"
    set ta_ready 1
    while {![file exists [file join $ta_dir stop]]} {
        ta_check_host
        set display [file join $ta_dir display.txt]
        if {[file exists $display]} {
            set f [open $display r]
            try {set data [string trim [read $f]]} finally {close $f}
            file delete $display
            if {[catch {ta_display $data} message]} {
                ta_publish "display-[lindex $data 0].txt" "ERROR $message"
                error $message
            }
        }
        set request [file join $ta_dir request.txt]
        if {![file exists $request]} {after 10;continue}
        set f [open $request r]
        try {set data [string trim [read $f]]} finally {close $f}
        file delete $request
        set next [lindex $data 0]
        if {![string is integer -strict $next] || $next != $ta_seq+1} {error "Invalid request sequence"}
        set ta_seq $next
        ta_publish "response-$ta_seq.txt" [ta_infer $ta_seq [lrange $data 1 end]]
    }
} on error {message options} {
    puts stderr "BOARD_SESSION_ERROR: $message"
    set message [string map [list \n " " \r " "] $message]
    if {!$ta_ready} {ta_publish ready.txt "ERROR $message"} elseif {$ta_seq > 0} {
        ta_publish "response-$ta_seq.txt" "ERROR $ta_seq $message"
    }
} finally {
    if {$ta_hex_recognized} {catch {master_write_32 $ta_h 0x20 {255}}}
    if {$ta_h ne ""} {close_service master $ta_h}
}
