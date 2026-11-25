# tailmouse asset pack

Artwork traced and smoothed from the approved reference. Six network dots are regularized to circles. The original lowercase wordmark is outlined; no fonts are required. No cursor.

- `logo`: transparent SVG and PNG marks and wordmarks.
- `app-icons`: full-bleed opaque 1024 px iOS icons, rounded macOS icons and ICNS.
- `menu-bar`: black alpha template, 23 × 18 pt, 1x/2x/3x.
- `Apple/Assets.xcassets`: iOSAppIcon, macOSAppIcon and MenuBarIcon sets. Copy the relevant sets into each target and choose the corresponding app icon set in Xcode. In SwiftUI use `Image("MenuBarIcon").renderingMode(.template)`; in AppKit set `isTemplate = true`.

Colors: charcoal #20242C, slate #707784, gradient #5988F3 to #5530C8.

The macOS and iOS asset catalogs are generated but have not been compiled in Xcode. iOS system applies its own icon mask. No custom tinted iOS variant is included.
