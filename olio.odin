package olio

import "core:sys/posix"
import "core:os"
import "core:fmt"

origin_termios: posix.termios

Result :: enum {
    Err,
    Ok,
}

main :: proc() {
    defer disable_raw_mode()
    enable_raw_mode()    
    for {
        handle_keypress()
    }
}

die :: proc(msg: string) {
    disable_raw_mode()
    fmt.println(msg)
    os.exit(1)
}

exit :: proc(code: int) {
    disable_raw_mode()
    os.exit(code)
}

is_cntl :: proc(b: byte) -> bool {
    return b <= 31 || b == 127
}

cntl_key :: proc(b: byte) -> byte {
    return b & 0x1f
}

read_key :: proc() -> byte {
    buffer: [1]byte
    for {
        nread, err := os.read(os.stdin, buffer[:])
        if err != nil do die("read byte error")
        if nread == 1 do break
    }
    return buffer[0]
}

handle_keypress :: proc() {
    switch read_key() {
    case cntl_key('q'): 
        exit(0)
    } 
}

enable_raw_mode :: proc() {
    if posix.tcgetattr(posix.STDIN_FILENO, &origin_termios) != posix.result.OK do die("tcgetattr error")
    raw := origin_termios
    raw.c_iflag -= {
        posix.CInput_Flag_Bits.BRKINT,
        posix.CInput_Flag_Bits.ICRNL,
        posix.CInput_Flag_Bits.INPCK,
        posix.CInput_Flag_Bits.ISTRIP,
        posix.CInput_Flag_Bits.IXON,
    }
    raw.c_oflag -= {
        posix.COutput_Flag_Bits.OPOST,
    }
    raw.c_cflag -= {
        posix.CControl_Flag_Bits.CS8,
    }
    raw.c_lflag -= {
        posix.CLocal_Flag_Bits.ECHO,
        posix.CLocal_Flag_Bits.ICANON,
        posix.CLocal_Flag_Bits.IEXTEN,
        posix.CLocal_Flag_Bits.ISIG,
    }
    raw.c_cc[posix.Control_Char.VMIN] = 0
    raw.c_cc[posix.Control_Char.VTIME] = 1
    if posix.tcsetattr(posix.STDIN_FILENO, posix.TC_Optional_Action.TCSAFLUSH, &raw) != posix.result.OK do die("tcsetattr error")
}

disable_raw_mode :: proc() {
    if posix.tcsetattr(posix.STDIN_FILENO, posix.TC_Optional_Action.TCSAFLUSH, &origin_termios) != posix.result.OK do die("tcsetattr error")
}


