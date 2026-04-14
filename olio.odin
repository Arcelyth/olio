package olio

import "core:sys/posix"
import "core:c/libc"
import "core:os"
import "core:fmt"
import "core:strings"
import "core:strconv"

Config :: struct {
    screen_row: int,
    screen_col: int,
    origin_termios: posix.termios
}

E: Config

Result :: enum {
    Err,
    Ok,
}

main :: proc() {
    defer disable_raw_mode()
    enable_raw_mode()    
    init_editor()
    for {
        refresh_screen()
        handle_keypress()
    }
}

init_editor :: proc() {
    if get_window_size(&E) == .Err do die("get window size error")
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

clear_screen :: proc() {
    os.write_string(os.stdin, "\x1b[2J")
    os.write_string(os.stdin, "\x1b[H")
}

draw_rows :: proc() {
    for r in 0..<E.screen_row {
        os.write_string(os.stdin, "~")
        if r < E.screen_row - 1 do os.write_string(os.stdin, "\r\n");
    }
}

refresh_screen :: proc() {
    clear_screen()
    draw_rows()
    os.write_string(os.stdin, "\x1b[H")
}

get_cursor_pos :: proc(conf: ^Config) -> Result {
    buf: [32]byte
    i := 0
    if _, err := os.write_string(os.stdin, "\x1b[6n"); err != nil do return .Err // report active position
    fmt.printf("\r\n")
    for i in 0..<size_of(buf) - 1 {
        if _, err := os.read(os.stdin, buf[i:i+1]); err != nil do break
        if buf[i] == 'R' do break
    }
    if buf[0] != '\x1b' || buf[1] != '[' do return .Err // parse the response which is a escape sequence
    res := buf[2:]
    if ss := strings.split(string(res), ";"); len(ss) == 2 {
        if res, err := strconv.parse_int(ss[0]); err != false do conf.screen_row = res
        if res, err := strconv.parse_int(ss[1]); err != false do conf.screen_col = res
    } 

    return .Ok
}

get_window_size :: proc(conf: ^Config) -> Result {
    if _, err := os.write_string(os.stdin, "\x1b[999C\x1b[999B"); err != nil do return .Err
    return get_cursor_pos(conf)
}

enable_raw_mode :: proc() {
    if posix.tcgetattr(posix.STDIN_FILENO, &E.origin_termios) != posix.result.OK do die("tcgetattr error")
    raw := E.origin_termios
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
    if posix.tcsetattr(posix.STDIN_FILENO, posix.TC_Optional_Action.TCSAFLUSH, &E.origin_termios) != posix.result.OK do die("tcsetattr error")
}


