// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax;

import androidx.annotation.NonNull;
import androidx.camera.core.ImageAnalysis.Analyzer;
import androidx.camera.core.ImageProxy;
import java.util.Objects;

/**
 * ProxyApi implementation for {@link Analyzer}. This class may handle instantiating native object
 * instances that are attached to a Dart instance or handle method calls on the associated native
 * class or an instance of that class.
 */
class AnalyzerProxyApi extends PigeonApiAnalyzer {
  AnalyzerProxyApi(@NonNull ProxyApiRegistrar pigeonRegistrar) {
    super(pigeonRegistrar);
  }

  @NonNull
  @Override
  public ProxyApiRegistrar getPigeonRegistrar() {
    return (ProxyApiRegistrar) super.getPigeonRegistrar();
  }

  /** Implementation of {@link Analyzer} that passes arguments of callback methods to Dart. */
  static class AnalyzerImpl implements Analyzer {
    final AnalyzerProxyApi api;

    AnalyzerImpl(@NonNull AnalyzerProxyApi api) {
      this.api = api;
    }

    @Override
    public void analyze(@NonNull ImageProxy image) {
      // The application can opt in to native biometric analysis. This keeps
      // CameraPreview's existing Flutter texture while avoiding the full-frame
      // ImageProxy -> Dart serialization path.
      if (NativeRetinaAnalyzer.analyze(image)) {
        return;
      }
      api.getPigeonRegistrar()
          .runOnMainThread(
              new ProxyApiRegistrar.FlutterMethodRunnable() {
                @Override
                public void run() {
                  api.analyze(
                      AnalyzerImpl.this,
                      image,
                      ResultCompat.asCompatCallback(
                          result -> {
                            if (result.isFailure()) {
                              onFailure(
                                  "Analyzer.analyze",
                                  Objects.requireNonNull(result.exceptionOrNull()));
                            }
                            return null;
                          }));
                }
              });
    }
  }

  @NonNull
  @Override
  public Analyzer pigeon_defaultConstructor() {
    return new AnalyzerImpl(this);
  }
}
