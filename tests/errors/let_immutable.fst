// 'let' is an immutable binding (Rust-style): reassignment must be rejected.
func main() -> int
{
    let x = 5;
    x = 6;
    return x;
}
