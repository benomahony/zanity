package sample
import "testing"
func TestRejectsConstantChecks(t *testing.T) {
    assert.True(t, true) // parity: constant
    require.Equal(t, 2, 1 + 1) // parity: constant
    assert.Equal(t, "abc", "abc") // parity: constant
    actual := calculate()
    assert.Equal(t, 2, actual)
    assert.Equal(t, actual, 2)
    assert.True(t, calculate() == 2)
    if unexpected() { assert.False(t, true) }
    other.Equal(t, 1, 1)
}
func helper(t *testing.T) { assert.Equal(t, 2, 2) }
