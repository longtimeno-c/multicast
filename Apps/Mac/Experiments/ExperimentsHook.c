// Runs before `main` so the experiments can live in this folder without touching the app's entry
// point. `MulticastExperimentsMain` returns at once unless the process was started with one of
// the experiment flags (see ExperimentsMain.swift); with a flag it runs the experiment and exits.
extern void MulticastExperimentsMain(void);

__attribute__((constructor)) static void multicast_experiments_hook(void) {
    MulticastExperimentsMain();
}
