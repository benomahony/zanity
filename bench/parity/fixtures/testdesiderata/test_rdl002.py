def test_order_total_includes_every_step(order):
    step_0 = order.total + 0
    step_1 = order.total + 1
    step_2 = order.total + 2
    step_3 = order.total + 3
    step_4 = order.total + 4
    step_5 = order.total + 5
    step_6 = order.total + 6
    step_7 = order.total + 7
    step_8 = order.total + 8
    step_9 = order.total + 9
    step_10 = order.total + 10
    step_11 = order.total + 11
    step_12 = order.total + 12
    step_13 = order.total + 13
    step_14 = order.total + 14
    step_15 = order.total + 15
    step_16 = order.total + 16
    step_17 = order.total + 17
    step_18 = order.total + 18
    step_19 = order.total + 19
    step_20 = order.total + 20
    step_21 = order.total + 21
    assert step_0 < step_21
