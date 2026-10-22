<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { copyToClipboard } from '@/lib/clipboard'
import EpubReader from './EpubReader.prototype.vue'
import PdfReader from './PdfReader.prototype.vue'
import { scenarios } from './scenarios'
import type { ProofManifest, ProofScenario, ReaderHandle } from './types'

interface Review {
  step: number
  checks: boolean[]
  answer: string
  feedback: string
  completed: boolean
  observations: Record<string, unknown>[]
}
const records = ref<Record<string, Review>>({})
const manifest = ref<ProofManifest | null>(null)
const loadProblem = ref('')
const currentId = ref<string | null>(null)
const reader = ref<ReaderHandle | null>(null)
const readerReady = ref(false)
const attempt = ref(0)
const busy = ref(false)
const actionProblem = ref('')
const stateMessage = ref('Opening the sample...')
const parameters = new URL(location.href).searchParams
const requestedBrowser = parameters.get('browser') ?? ''
const browser = ref(['mac-chrome', 'mac-vivaldi', 'android-chrome', 'preliminary-preview'].includes(requestedBrowser) ? requestedBrowser : '')
const browserVersion = ref(parameters.get('version') ?? '')
const reportText = ref<HTMLTextAreaElement | null>(null)
const copyMessage = ref('')
const current = computed(() => scenarios.find((scenario) => scenario.id === currentId.value))
const review = computed(() => (current.value ? records.value[current.value.id] : undefined))
const step = computed(() => current.value?.steps[review.value?.step ?? 0])
const atVerdict = computed(() => Boolean(current.value && review.value && review.value.step >= current.value.steps.length))
const reviewedCount = computed(() => Object.values(records.value).filter((record) => record.completed).length)
const summary = computed(() => ({
  title: 'BookOrbit browser reading review',
  recordedUTC: new Date().toISOString(),
  browser: browser.value,
  browserVersion: browserVersion.value || 'not recorded',
  userAgent: navigator.userAgent,
  viewport: { width: window.innerWidth, height: window.innerHeight, pixelRatio: window.devicePixelRatio },
  transfer: manifest.value?.transfer,
  scenarios: scenarios.map((scenario) => ({ id: scenario.id, title: scenario.title, ...records.value[scenario.id] })),
}))
const summaryText = computed(() =>
  [
    'BookOrbit browser reading review',
    `${reviewedCount.value} of ${scenarios.length} walkthroughs reviewed`,
    `Browser: ${browser.value || 'not selected'} ${browserVersion.value}`,
    ...scenarios.map((scenario) => {
      const record = records.value[scenario.id]
      return `\n${scenario.title}\n${record?.completed ? record.answer : 'Not reviewed'}\nChecks tried: ${record?.checks.filter(Boolean).length ?? 0}/${scenario.steps.length}${record?.feedback ? `\nFeedback: ${record.feedback}` : ''}`
    }),
  ].join('\n'),
)

function start(scenario: ProofScenario) {
  attempt.value++
  records.value[scenario.id] = { step: 0, checks: scenario.steps.map(() => false), answer: '', feedback: '', completed: false, observations: [] }
  currentId.value = scenario.id
  readerReady.value = false
  actionProblem.value = ''
  stateMessage.value = "Opening this walkthrough's own sample..."
  window.scrollTo({ top: 0 })
}
function backToList() {
  currentId.value = null
  readerReady.value = false
  window.scrollTo({ top: 0 })
}
function restart() {
  if (!current.value || !confirm('Restart only this sample walkthrough and its review answers? Your original iPad notes are not changed.')) return
  start(current.value)
}
function setReady(value: boolean) {
  readerReady.value = value
}
function setMessage(value: string) {
  stateMessage.value = value
}
async function runAction() {
  if (!step.value || !reader.value) return
  busy.value = true
  actionProblem.value = ''
  try {
    await reader.value.act(step.value.action)
    review.value?.observations.push({ action: step.value.action, ...reader.value.evidence() })
  } catch (error) {
    actionProblem.value = error instanceof Error ? error.message : String(error)
  } finally {
    busy.value = false
  }
}
function nextStep() {
  if (!review.value || !review.value.checks[review.value.step]) return
  review.value.observations.push({ step: review.value.step + 1, ...reader.value?.evidence() })
  review.value.step++
  actionProblem.value = ''
}
function previousStep() {
  if (review.value) review.value.step = Math.max(0, review.value.step - 1)
}
function reportProblem() {
  if (!review.value || !current.value) return
  review.value.feedback = `Step ${review.value.step + 1}: `
  review.value.answer = 'I could not complete this walkthrough'
  review.value.step = current.value.steps.length
}
function recordAnswer() {
  if (!review.value?.answer || !browser.value) return
  review.value.completed = true
  backToList()
}
function downloadReview() {
  const url = URL.createObjectURL(new Blob([JSON.stringify(summary.value, null, 2)], { type: 'application/json' }))
  const link = document.createElement('a')
  link.href = url
  link.download = `bookorbit-browser-review-${browser.value || 'preview'}.json`
  link.click()
  URL.revokeObjectURL(url)
}
async function copyReview() {
  if (await copyToClipboard(summaryText.value)) {
    copyMessage.value = 'Review summary copied.'
  } else {
    reportText.value?.select()
    copyMessage.value = "The summary is selected. Use your browser's Copy action."
  }
}

const diagnostics = {
  evidence: () => ({ ...summary.value, current: current.value?.id, reader: reader.value?.evidence(), readerReady: readerReady.value }),
  act: (action: string) => reader.value?.act(action),
  selectionText: () => reader.value?.selectionText?.(),
  open: (id: string) => {
    const scenario = scenarios.find((item) => item.id === id)
    if (scenario) start(scenario)
  },
}
onMounted(async () => {
  Object.assign(window, { bookorbitBrowserProof: diagnostics })
  try {
    const response = await fetch('/proof-input/manifest.json')
    if (!response.ok) throw new Error('The sample notes could not be loaded.')
    manifest.value = await response.json()
    const requestedScenario = scenarios.find((scenario) => scenario.id === parameters.get('scenario'))
    if (requestedScenario) start(requestedScenario)
  } catch (error) {
    loadProblem.value = error instanceof Error ? error.message : String(error)
  }
})
onUnmounted(() => {
  Reflect.deleteProperty(window, 'bookorbitBrowserProof')
})
</script>

<template>
  <main class="mx-auto min-h-screen max-w-4xl bg-background px-4 py-6 text-foreground sm:px-6 sm:py-10">
    <template v-if="!current">
      <p class="mb-2 text-xs font-semibold uppercase tracking-wider text-primary">Throwaway prototype</p>
      <h1 class="text-2xl font-semibold sm:text-3xl">Read your iPad notes in a browser</h1>
      <p class="mt-3 max-w-2xl text-muted-foreground">
        Check that PDF handwriting stays on its page and EPUB notes stay linked to their selected words. Start any walkthrough. Each includes its own
        sample and complete instructions.
      </p>
      <p class="mt-2 text-sm text-muted-foreground">
        This uses saved sample notes and a local transfer. It does not connect to your BookOrbit library. Review answers stay in this tab until you
        close or reload it.
      </p>
      <div class="my-5 flex flex-wrap gap-3 rounded-lg border border-border p-4">
        <label class="flex flex-col gap-1 text-sm"
          >I am reviewing in
          <select v-model="browser" class="rounded border border-input bg-background px-3 py-2">
            <option value="" disabled>Choose this browser</option>
            <option value="mac-chrome">Chrome on Mac</option>
            <option value="mac-vivaldi">Vivaldi on Mac</option>
            <option value="android-chrome">Chrome on Android</option>
            <option value="preliminary-preview">Preliminary browser preview</option>
          </select>
        </label>
        <label class="flex flex-col gap-1 text-sm"
          >Browser version, if known
          <input v-model="browserVersion" class="rounded border border-input bg-background px-3 py-2" placeholder="For example, 154.0.8037.98" />
        </label>
      </div>
      <p class="mb-3 font-medium">{{ reviewedCount }} of {{ scenarios.length }} walkthroughs reviewed</p>
      <p v-if="loadProblem" role="alert" class="my-3 text-destructive">{{ loadProblem }}</p>
      <div class="grid gap-3 sm:grid-cols-2">
        <article v-for="scenario in scenarios" :key="scenario.id" class="flex flex-col items-start rounded-lg border border-border p-4">
          <span class="text-xs font-medium text-primary">{{ scenario.original ? 'iPad check, can wait' : scenario.format.toUpperCase() }}</span>
          <h2 class="my-2 font-semibold">{{ scenario.title }}</h2>
          <p class="mb-4 flex-1 text-sm text-muted-foreground">{{ scenario.aim }}</p>
          <p v-if="records[scenario.id]?.completed" class="mb-3 text-sm">Recorded: {{ records[scenario.id]?.answer }}</p>
          <button
            :disabled="!manifest || !browser"
            class="rounded bg-primary px-3 py-2 text-sm font-medium text-primary-foreground disabled:opacity-40"
            @click="start(scenario)"
          >
            {{ records[scenario.id]?.completed ? 'Review again with a fresh sample' : 'Start this walkthrough' }}
          </button>
        </article>
      </div>
      <section v-if="reviewedCount" class="mt-8 rounded-lg border border-border p-4">
        <h2 class="mb-3 font-semibold">Your review so far</h2>
        <textarea
          ref="reportText"
          :value="summaryText"
          readonly
          class="h-64 w-full rounded border border-input bg-background p-3 text-sm"
          aria-label="Review summary"
        />
        <div class="mt-3 flex flex-wrap gap-2">
          <button class="rounded border border-border px-3 py-2 text-sm" @click="copyReview">Copy review summary</button>
          <button class="rounded border border-border px-3 py-2 text-sm" @click="downloadReview">Save detailed review file</button>
        </div>
        <p aria-live="polite" class="mt-2 text-sm">{{ copyMessage }}</p>
      </section>
    </template>
    <template v-else-if="review && manifest">
      <button class="mb-5 text-sm font-medium text-primary underline" @click="backToList">All walkthroughs</button>
      <h1 class="text-2xl font-semibold">{{ current.title }}</h1>
      <p class="mt-2 text-muted-foreground">{{ current.aim }}</p>
      <section v-if="step && !atVerdict" class="my-5 rounded-lg border border-primary p-4" aria-label="Current walkthrough step">
        <p class="text-xs font-semibold text-primary">Step {{ review.step + 1 }} of {{ current.steps.length }}</p>
        <h2 class="my-2 text-lg font-semibold">{{ step.title }}</h2>
        <p class="text-sm">{{ step.instruction }}</p>
        <button
          :disabled="!readerReady || busy"
          class="my-3 rounded bg-primary px-4 py-2 font-medium text-primary-foreground disabled:opacity-40"
          @click="runAction"
        >
          {{ busy ? 'Updating the sample...' : step.button }}
        </button>
        <p class="mb-3 text-sm"><strong>Expected:</strong> {{ step.expected }}</p>
        <label class="flex items-start gap-3 text-sm"
          ><input v-model="review.checks[review.step]" type="checkbox" class="mt-1" />{{ step.check }}</label
        >
        <p class="mt-2 text-xs text-muted-foreground">Tick after trying the check, even if it failed. Your final answer records whether it worked.</p>
        <p v-if="actionProblem" role="alert" class="mt-3 text-sm text-destructive">{{ actionProblem }}</p>
        <div class="mt-4 flex flex-wrap gap-2">
          <button :disabled="review.step === 0" class="rounded border border-border px-3 py-2 text-sm disabled:opacity-40" @click="previousStep">
            Back one step
          </button>
          <button
            :disabled="!review.checks[review.step] || busy"
            class="rounded bg-primary px-4 py-2 text-sm text-primary-foreground disabled:opacity-40"
            @click="nextStep"
          >
            Continue
          </button>
          <button class="rounded border border-border px-3 py-2 text-sm" @click="reportProblem">I could not finish this step</button>
        </div>
      </section>
      <section v-else class="my-5 rounded-lg border border-primary p-4">
        <h2 class="mb-3 text-lg font-semibold">{{ current.question }}</h2>
        <label
          v-for="answer in [current.yes, current.no, 'I could not complete this walkthrough']"
          :key="answer"
          class="mb-3 flex items-start gap-3 text-sm"
        >
          <input v-model="review.answer" type="radio" :value="answer" class="mt-1" />{{ answer }}
        </label>
        <label class="mt-4 block text-sm"
          >If anything failed, describe the step and what happened.
          <textarea v-model="review.feedback" class="mt-2 min-h-24 w-full rounded border border-input bg-background p-3" />
        </label>
        <p class="my-3 text-xs text-muted-foreground">
          {{ review.checks.filter(Boolean).length }} of {{ current.steps.length }} checks tried. You can revisit the reader below before answering.
        </p>
        <button :disabled="!review.answer" class="rounded bg-primary px-4 py-2 text-primary-foreground disabled:opacity-40" @click="recordAnswer">
          Record this answer
        </button>
        <button class="ml-3 rounded border border-border px-3 py-2 text-sm" @click="previousStep">Back to the steps</button>
      </section>
      <p role="status" aria-live="polite" class="mb-3 text-sm text-muted-foreground">{{ stateMessage }}</p>
      <EpubReader
        v-if="current.format === 'epub'"
        :key="attempt"
        ref="reader"
        :manifest="manifest"
        :typed="current.typed"
        @ready="setReady"
        @change="setMessage"
      />
      <PdfReader v-else :key="attempt" ref="reader" :manifest="manifest" @ready="setReady" @change="setMessage" />
      <div class="mt-5 flex flex-wrap items-center gap-3">
        <button class="rounded border border-border px-3 py-2 text-xs" @click="restart">Restart this walkthrough</button>
        <span class="text-xs text-muted-foreground">{{ manifest.transfer }}</span>
      </div>
      <details class="mt-4 rounded border border-border p-3 text-xs text-muted-foreground">
        <summary class="cursor-pointer">Technical evidence for this sample</summary>
        <p class="my-2">
          {{ current.format === 'epub' ? manifest.epub.association : 'Actual cropped and rotated PDF with original physical iPad ink.' }}
        </p>
        <p class="break-all">
          Editable original SHA-256: {{ current.format === 'epub' ? manifest.epub.originalSha256 : manifest.pdf.originalSha256 }}
        </p>
        <p class="mt-2">Viewing a derivative does not prove the original is still editable. The separate iPad walkthrough checks that.</p>
      </details>
    </template>
  </main>
</template>
