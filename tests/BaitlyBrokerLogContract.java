import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.util.Properties;
import java.nio.file.Files;
import java.nio.file.Path;
import org.apache.log4j.*;

/** Run against the broker image's logging jars, without starting a broker/container. */
public final class BaitlyBrokerLogContract {
    public static void main(String[] args) throws Exception {
        Properties config = new Properties();
        try (var input = Files.newInputStream(Path.of(args[0]))) { config.load(input); }
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        PrintStream original = System.out;
        String privateValue = "SYNTHETIC_PRIVATE_token_email@example.test_PIN_92841";
        try {
            System.setOut(new PrintStream(bytes, true, StandardCharsets.UTF_8));
            PropertyConfigurator.configure(config);
            Logger logger = Logger.getLogger(privateValue);
            MDC.put("orgId", privateValue);
            NDC.push(privateValue);
            String thread = Thread.currentThread().getName();
            try {
                Thread.currentThread().setName(privateValue);
                RuntimeException failure = new RuntimeException(privateValue, new Exception(privateValue));
                failure.addSuppressed(new Exception(privateValue));
                for (Level level : new Level[]{Level.INFO, Level.WARN, Level.ERROR, Level.FATAL}) {
                    logger.log(level, privateValue, failure);
                }
                logger.debug(privateValue);
                // A payload must never be formatted, even when logging is enabled.
                logger.error(new Object() {
                    public String toString() { throw new AssertionError("Payload was evaluated"); }
                });
            } finally {
                Thread.currentThread().setName(thread);
                MDC.clear();
                NDC.clear();
            }
        } finally {
            LogManager.shutdown();
            System.setOut(original);
        }
        String logs = bytes.toString(StandardCharsets.UTF_8);
        String[] lines = logs.lines().toArray(String[]::new);
        if (lines.length != 5 || logs.contains(privateValue) || logs.contains("92841")) {
            throw new AssertionError("Broker diagnostic contract failed (output withheld)");
        }
        for (String line : lines) {
            if (!line.matches("\\{\"diagnostic\":\"BAITLY_BROKER\",\"level\":\"(INFO|WARN|ERROR|FATAL)\",\"timestamp\":\"[0-9TZ:.+\\-]+\"\\}")) {
                throw new AssertionError("Unexpected broker log schema (output withheld)");
            }
        }
        System.out.println("Baitly broker diagnostic contract: 5 safe records; payload/context/causes absent");
    }
}
