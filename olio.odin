package olio

import "core:sys/posix"
import "core:c/libc"
import "core:os"
import "core:fmt"
import "core:strings"
import "core:strconv"
import "core:bytes"

Config :: struct {      // editor's config
    screen_row: int,
    screen_col: int,
    origin_termios: posix.termios
}

Buffer :: bytes.Buffer  // append buffer

E: Config

Result :: enum {
    Err,
    Ok,
}

Olio_Version := "0.0.1"

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

clear_screen :: proc(buf: ^Buffer) {
    bytes.buffer_write_string(buf, "\x1b[2J")
    bytes.buffer_write_string(buf, "\x1b[H")
}

draw_rows :: proc(buf: ^Buffer) {
    for r in 0..<E.screen_row {
        if r == E.screen_row / 3 {
            wel := fmt.tprintf("Olio editor -- version %s", Olio_Version)
            if len(wel) > E.screen_col do wel = strings.cut(wel, 0, E.screen_col)
            padding := (E.screen_col - len(wel)) / 2
            if padding > 0 {
                bytes.buffer_write_string(buf, "~")
                padding -= 1
            }
            for _ in 0..<padding do bytes.buffer_write_string(buf, " ") 
            bytes.buffer_write_string(buf, wel)
        } else {
            bytes.buffer_write_string(buf, "~")
        }
        bytes.buffer_write_string(buf, "\x1b[K")    // erase in line
        if r < E.screen_row - 1 do bytes.buffer_write_string(buf, "\r\n") 
    }
}

refresh_screen :: proc() {
    buffer: Buffer
    bytes.buffer_write_string(&buffer, "\x1b[?25l")
    bytes.buffer_write_string(&buffer, "\x1b[H")
    draw_rows(&buffer)
    bytes.buffer_write_string(&buffer, "\x1b[H")
    bytes.buffer_write_string(&buffer, "\x1b[?25h")
    os.write_string(os.stdin, bytes.buffer_to_string(&buffer))
}

get_cursor_pos :: proc(conf: ^Config) -> Result {
    buf: [dynamic]byte
    if _, err := os.write_string(os.stdin, "\x1b[6n"); err != nil do return .Err // report active position
    fmt.printf("\r\n")
    for i in 0..<size_of(buf) - 1 {
        b: [1]byte
        if _, err := os.read(os.stdin, b[:]); err != nil do break
        if b[0] == 'R' do break
        append(&buf, b[0])
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


