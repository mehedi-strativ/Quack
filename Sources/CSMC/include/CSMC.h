#ifndef CSMC_H
#define CSMC_H

/// Reads CPU temperature from the Apple System Management Controller (SMC) over
/// IOKit — the same source the `hot` and `stats` apps use. The SMC connection is
/// opened lazily; on first use the key list is enumerated and the CPU
/// temperature sensors are discovered, so it works across Intel and Apple
/// Silicon without hardcoding chip-specific keys.

/// Average CPU temperature in degrees Celsius, or -1 if unavailable.
double csmc_cpu_temperature(void);

/// Closes the SMC connection (optional; safe if never opened).
void csmc_close(void);

#endif /* CSMC_H */
