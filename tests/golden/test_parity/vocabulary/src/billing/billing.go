package billing

import "testing"

func LoadClient(id int) int {
	return id
}

func StringUtil(text string) string {
	return text
}

func InvoiceTotal(amount int) int {
	return amount
}

func TestParcelLabel(t *testing.T) {
	t.Log("label")
}
