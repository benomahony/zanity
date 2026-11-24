package orders

import (
	"testing"

	"github.com/golang/mock/gomock"
)

func TestChargesThroughGateway(t *testing.T) {
	ctrl := gomock.NewController(t)
	gateway := NewMockGateway(ctrl)
	if NewOrders(gateway).Charge(1) != nil {
		t.Fatal("expected charging order 1 to succeed")
	}
}

func checkQueue(queue *Queue) {
	if queue.Pop() == nil {
		panic("the queue must hold the order that was pushed before draining it")
	}
	if queue.Len() == 0 {
		panic("the queue must not be empty once an order was pushed")
	}
}
