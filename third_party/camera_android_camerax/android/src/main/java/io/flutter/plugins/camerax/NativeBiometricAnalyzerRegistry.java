package io.flutter.plugins.camerax;

import androidx.annotation.Nullable;
import androidx.camera.core.ImageProxy;

/**
 * Optional application-owned analyzer. CameraPreview continues to use the
 * plugin texture; only ImageAnalysis delivery is intercepted when biometric
 * scan mode explicitly enables this hook.
 */
public final class NativeBiometricAnalyzerRegistry {
  public interface Analyzer {
    /** Returns true only when ownership of, and responsibility for closing, image is accepted. */
    boolean analyze(ImageProxy image);
  }

  @Nullable private static volatile Analyzer analyzer;

  private NativeBiometricAnalyzerRegistry() {}

  public static void setAnalyzer(@Nullable Analyzer value) {
    analyzer = value;
  }

  public static boolean dispatch(ImageProxy image) {
    final Analyzer current = analyzer;
    return current != null && current.analyze(image);
  }
}
