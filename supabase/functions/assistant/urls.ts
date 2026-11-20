import type { Config } from './handler.ts';

// Container addresses are for server I/O, never phone links or OAuth callbacks.
export const publicURL = (config: Config) => (config.publicUrl || config.url).replace(/\/$/, '');
