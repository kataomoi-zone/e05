import SQLite3

// SQLITE_TRANSIENT tells SQLite to copy the string immediately, avoiding dangling pointers.
// Kept verbatim from SQLite's C macro (not importable into Swift) for parity with the C API.
// swift-format-ignore: AlwaysUseLowerCamelCase
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
