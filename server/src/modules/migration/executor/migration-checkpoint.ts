export const MIGRATION_EXECUTION_CHECKPOINT = Symbol('MIGRATION_EXECUTION_CHECKPOINT');

export type MigrationExecutionCheckpoint = (input: { runId: number; stage: string; batchIndex: number }) => Promise<void>;
