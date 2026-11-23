import com.github.jknack.handlebars.Handlebars;
import java.nio.file.Files;
import java.nio.file.Path;

class Sinks {
    String read(Path path) throws Exception {
        return Files.readString(path);
    }

    String readFixed() throws Exception {
        return Files.readString(Path.of("/etc/orders.conf"));
    }

    Object render(Handlebars handlebars, String source) throws Exception {
        return handlebars.compileInline(source);
    }

    Object renderFixed(Handlebars handlebars) throws Exception {
        return handlebars.compileInline("Hello {{name}}");
    }
}
