package olio

import "core:sys/posix"
import "core:os"
import "core:fmt"

main :: proc() {
    enable_raw_mode()
    buffer: [1]byte
    loop: for {
        count, err := os.read(os.stdin, buffer[:]) 
        if err != nil {
            fmt.println("Error reading input:", err)
            return
        }
        c := buffer[0]
        if count != 1 || c == 'q' {
            break loop
        }
        fmt.printf("%d", c)
    }
}

enable_raw_mode :: proc() {
    raw: posix.termios
    posix.tcgetattr(posix.STDIN_FILENO, &raw)
    raw.c_lflag -= {posix.CLocal_Flag_Bits.ECHO}
    posix.tcsetattr(posix.STDIN_FILENO, posix.TC_Optional_Action.TCSAFLUSH, &raw)
}



