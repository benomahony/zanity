import java.sql.Statement;
import java.util.logging.Logger;
import javax.crypto.spec.PBEKeySpec;

class Rules {
    private static final Logger logger = Logger.getLogger("orders");

    PBEKeySpec derive(char[] password) {
        return new PBEKeySpec(password, "shared-salt".getBytes(), 65536, 256);
    }

    PBEKeySpec deriveSalted(char[] password, byte[] salt) {
        return new PBEKeySpec(password, salt, 65536, 256);
    }

    void note(String apiToken) {
        logger.info("using " + apiToken);
    }

    void noteOrder(int order) {
        logger.info("placed " + order);
    }

    void find(Statement statement, String name) throws Exception {
        statement.executeQuery("SELECT * FROM users WHERE name = '" + name + "'");
        statement.executeQuery("SELECT * FROM users");
    }
}
