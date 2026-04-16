import SQLite3

// SQLITE_TRANSIENT tells SQLite to copy the string immediately, avoiding dangling pointers.
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
