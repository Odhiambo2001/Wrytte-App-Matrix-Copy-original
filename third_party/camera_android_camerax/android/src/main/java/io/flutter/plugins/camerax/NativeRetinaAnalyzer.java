package io.flutter.plugins.camerax;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.camera.core.ImageProxy;
import java.util.concurrent.Executor;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Optional application-owned analyzer hook.
 *
 * <p>The stock camera plugin serializes each {@link ImageProxy} through Dart
 * for {@code startImageStream}. When enabled, this hook keeps the same
 * CameraX preview texture but delivers the image directly to the application
 * native analyzer. The processor must always close the image.
 */
public final class NativeRetinaAnalyzer {
  public interface Processor {
    void analyze(@NonNull ImageProxy image);
  }

  private static final ExecutorService EXECUTOR =
      Executors.newSingleThreadExecutor(
          runnable -> {
            final Thread thread = new Thread(runnable, "wrytte-retina-camera");
            thread.setDaemon(true);
            return thread;
          });

  @Nullable private static volatile Processor processor;
  private static volatile boolean enabled;

  private NativeRetinaAnalyzer() {}

  public static void setProcessor(@Nullable Processor value) {
    processor = value;
  }

  public static void setEnabled(boolean value) {
    enabled = value;
  }

  public static boolean isEnabled() {
    return enabled && processor != null;
  }

  @NonNull
  public static Executor executor() {
    return EXECUTOR;
  }

  /** Returns true only when native code owns and will close this image. */
  public static boolean analyze(@NonNull ImageProxy image) {
    final Processor current = processor;
    if (!enabled || current == null) {
      return false;
    }
    current.analyze(image);
    return true;
  }
}
