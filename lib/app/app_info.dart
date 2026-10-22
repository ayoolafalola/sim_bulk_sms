/// Shown on the home screen, in the app and in notifications.
const appName = 'Messages++';
/// The name in the stores.
const appFullName = 'Messages++ by Comeriver';

/// The Google Play "store" build: no SMS-sending permission and no background
/// send service; messages go through the Messages app and schedules remind
/// you. Set with `--dart-define=STORE_BUILD=true` (Gradle reads the same flag
/// and removes those permissions from the manifest). See docs/RELEASE.md.
const isStoreBuild = bool.fromEnvironment('STORE_BUILD');
