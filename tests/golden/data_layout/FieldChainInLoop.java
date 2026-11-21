import java.util.List;

class FieldChainInLoop {
    static long totals(List<Row> rows) {
        long out = 0;
        for (Row row : rows) {
            out += row.customer.balance;
        }
        return out;
    }

    static long direct(List<Row> rows) {
        long out = 0;
        for (Row row : rows) {
            out += row.balance;
        }
        return out;
    }
}
