package olio

import "core:sys/posix"
import "core:os"
import "core:fmt"

origin_termios: posix.termios

main :: proc() {
    enable_raw_mode()
    defer disable_raw_mode()
    
    buffer: [1]byte
    loop: for {
        if count, err := os.read(os.stdin, buffer[:]); err != nil || count != 1 {
            return
        }
        c := buffer[0]
        if c == 'q' do break loop
        if is_cntl(c) do fmt.printf("%d\r\n", c)
        else do fmt.printf("%d ('%c')\r\n", c, c)
    }
}

is_cntl :: proc(b: byte) -> bool {
    return b < 31 || b == 127
}

enable_raw_mode :: proc() {
    posix.tcgetattr(posix.STDIN_FILENO, &origin_termios)
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
    posix.tcsetattr(posix.STDIN_FILENO, posix.TC_Optional_Action.TCSAFLUSH, &raw)
}

disable_raw_mode :: proc() {
    posix.tcsetattr(posix.STDIN_FILENO, posix.TC_Optional_Action.TCSAFLUSH, &origin_termios)
}


