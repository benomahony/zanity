def report(orders, rate, out):
    paid = [o for o in orders if o.paid]
    unpaid = [o for o in orders if not o.paid]
    total = 0
    for order in paid:
        total += order.amount * rate
    lines = []
    lines.append("Report")
    lines.append("======")
    lines.append(f"paid: {len(paid)}")
    lines.append(f"unpaid: {len(unpaid)}")
    lines.append(f"total: {total}")
    header = "\n".join(lines)
    summary = {}
    summary["count"] = len(orders)
    summary["paid"] = len(paid)
    summary["ratio"] = len(paid) / max(len(orders), 1)
    summary["rate"] = rate
    summary["total"] = total
    out.write(header)
    out.write("\n")
    for key in sorted(summary):
        out.write(f"{key}: {summary[key]}\n")
    out.write("\n")
    out.flush()
    notes = []
    if total > 1000:
        notes.append("large")
    if unpaid:
        notes.append("chase unpaid")
    out.write(", ".join(notes))
    out.write("line 0\n")
    out.write("line 1\n")
    out.write("line 2\n")
    out.write("line 3\n")
    out.write("line 4\n")
    out.write("line 5\n")
    out.write("line 6\n")
    out.write("line 7\n")
    out.write("line 8\n")
    out.write("line 9\n")
    out.write("line 10\n")
    out.write("line 11\n")
    out.write("line 12\n")
    out.write("line 13\n")
    out.write("line 14\n")
    out.write("line 15\n")
    out.write("line 16\n")
    out.write("line 17\n")
    out.write("line 18\n")
    out.write("line 19\n")
    out.write("line 20\n")
    out.write("line 21\n")
    out.write("line 22\n")
    out.write("line 23\n")
    out.write("line 24\n")
    out.write("line 25\n")
    out.write("line 26\n")
    out.write("line 27\n")
    out.write("line 28\n")
    out.write("line 29\n")
    return total


def early_exit(orders):
    count = 0
    for order in orders:
        if order.cancelled:
            return -1
        count += 1
    return count
