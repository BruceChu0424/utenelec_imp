export async function register() {
  if (process.env.NEXT_RUNTIME === 'nodejs') {
    const { assertAuthRuntimeConfiguration } = await import('./lib/auth-secret');
    assertAuthRuntimeConfiguration();
  }
}
