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
    if enable_raw_mode() != .Ok {
        return
    }
    
    loop: for {
        buffer: [1]byte
        if count, err := os.read(os.stdin, buffer[:]); err != nil {
            return
        }
        c := buffer[0]
        if c == 'q' do break loop
        if is_cntl(c) do fmt.printf("%d\r\n", c)
        else do fmt.printf("%d ('%c')\r\n", c, c)
    }
}

is_cntl :: proc(b: byte) -> bool {
    return b <= 31 || b == 127
}

enable_raw_mode :: proc() -> Result {
    if posix.tcgetattr(posix.STDIN_FILENO, &origin_termios) != posix.result.OK {
        fmt.printf("tcgetattr error")
        return .Err
    }
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
    if posix.tcsetattr(posix.STDIN_FILENO, posix.TC_Optional_Action.TCSAFLUSH, &raw) != posix.result.OK {
        fmt.printf("tcsetattr error")
        return .Err
    }

    return .Ok
}

disable_raw_mode :: proc() {
    posix.tcsetattr(posix.STDIN_FILENO, posix.TC_Optional_Action.TCSAFLUSH, &origin_termios)
}


