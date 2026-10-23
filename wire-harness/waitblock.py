"""Poll for a new durable block (deterministic signal for the P4 kill)."""
import glob, time


def wait_new_block(root, before, tries=6000, step=0.01):
    """Return None once block-*.bin count exceeds `before`, else the TIMEOUT message."""
    for _ in range(tries):
        if len(glob.glob(f"{root}/.axverity-store/*/block-*.bin")) > before:
            return None
        time.sleep(step)
    return f"TIMEOUT: no new durable block within {tries * step:.0f} s; kill NOT sent"
