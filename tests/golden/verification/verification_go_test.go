package verification

import "testing"

func TestSavesTheOrder(t *testing.T) {
	repo := new(MockRepo)
	repo.On("Save", order).Return(nil)
	service.Save(order)
	repo.AssertExpectations(t)
	repo.AssertCalled(t, "Save", order)
}
