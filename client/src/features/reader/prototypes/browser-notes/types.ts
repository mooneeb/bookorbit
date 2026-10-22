export interface ProofManifest {
  epub: {
    quote: string
    cfi: string
    sourceSha256: string
    originalSha256: string
    previewSha256: string
    renderer: string
    association: string
    nativeWalkthrough: string
  }
  pdf: {
    sourceSha256: string
    originalSha256: string
    previewSha256: string
    width: number
    height: number
    nativeCanvas: { width: number; height: number }
    canvasToPage: [number, number, number, number, number, number]
    nativeWalkthrough: string
  }
  transfer: string
}

export interface ReaderHandle {
  act: (action: string) => Promise<void>
  evidence: () => Record<string, unknown>
  selectionText?: () => Promise<string[]>
}

export interface ProofStep {
  title: string
  instruction: string
  action: string
  button: string
  expected: string
  check: string
}

export interface ProofScenario {
  id: string
  title: string
  aim: string
  format: 'epub' | 'pdf'
  typed?: boolean
  original?: boolean
  question: string
  yes: string
  no: string
  steps: ProofStep[]
}
