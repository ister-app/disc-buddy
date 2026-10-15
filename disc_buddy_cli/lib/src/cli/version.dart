/// Version string baked in at compile time:
/// `dart compile exe -DDISC_BUDDY_VERSION=v1.2.3 ...`. "dev" otherwise.
const String buildVersion =
    String.fromEnvironment('DISC_BUDDY_VERSION', defaultValue: 'dev');
