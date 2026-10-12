package shop

import (
	"testing"

	. "github.com/onsi/gomega"
)

func TestTotalIncludesTax(t *testing.T) {
	g := NewWithT(t)
	g.Expect(Total()).To(Equal(110))
}

func TestTotalIsPositive(t *testing.T) {
	RegisterTestingT(t)
	Expect(Total()).ShouldNot(BeZero())
}

func TestTotalWithoutMatcher(t *testing.T) {
	g := NewWithT(t)
	g.Expect(Total())
}
