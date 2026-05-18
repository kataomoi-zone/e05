/// Single source of truth for the `os.Logger` subsystem string. All
/// loggers in the app pass this as their `subsystem:` so a future
/// bundle-id rename or log-stream filter has one place to look.
public enum LogSubsystem {
  public static let app = "com.kawarimidoll.e05"
}
