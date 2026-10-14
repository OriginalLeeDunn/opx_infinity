import { computed, ref } from 'vue'

/**
 * The one thing the chat's two halves have to agree on.
 *
 * The box is two concerns on two layers -- the LOG on the overlay, which is never
 * focused, and the INPUT line on the modal layer, which takes the keyboard -- and
 * Lua treats them as two independent views: every payload names the layer it
 * belongs to and each half ignores the other's.
 *
 * That split is right everywhere but here. A line in the log fades after
 * `fadeMs` WHILE THE BOX IS CLOSED, and stays put while it is open, so the log
 * has to know something that only ever happens on the other layer. The
 * alternative is the log peeking at payloads addressed to the input, which makes
 * the "ignore the other's payloads" rule true except once -- an exception nobody
 * would find later.
 *
 * So: one flag, written by the input line, read by the log. Nothing else crosses.
 */
const open = ref(false)

/** Whether the input line currently holds the keyboard. */
export const inputOpen = computed(() => open.value)

export function setInputOpen(value: boolean): void {
  open.value = value
}

/**
 * HOW TALL THE INPUT BLOCK IS, IN PIXELS, while it is open.
 *
 * The second thing the two halves have to agree on, and for the same reason as
 * the flag above: the log has to get out of the way of a surface that lives on
 * the other layer and whose height it cannot predict. That height is the field
 * row plus however many completions are on screen -- one to eight rows, changing
 * with every keystroke -- so the clearance the log leaves cannot be a constant in
 * a stylesheet. It is measured on the input line and read here.
 *
 * Zero while the box is closed.
 */
const height = ref(0)

/** How tall the input block is right now, in CSS pixels. */
export const inputHeight = computed(() => height.value)

export function setInputHeight(value: number): void {
  height.value = value
}

/**
 * HOW TALL THE FIELD ROW ALONE IS, in pixels, while the box is open: the block
 * above minus the completion list. Zero while the box is closed.
 */
const field = ref(0)

export function setFieldHeight(value: number): void {
  field.value = value
}

/** The room the log's resting place leaves under it for the input line at a bottom
    anchor: `--op-space-6`, the distance the input's resting line hangs below the log. */
export const RESTING_BOTTOM = 32

/** The gap kept between the input block and the log. `--op-space-2`. */
export const CLEARANCE = 8

/**
 * HOW FAR BELOW ITS RESTING LINE THE INPUT HANGS at a bottom anchor (#120).
 *
 * The field row is 38px -- its padding and the keycaps -- and the room the log
 * leaves is 32px, so opening the box used to lift the whole log by the difference
 * plus the clearance, every time, with nothing typed. The owner kept the log's
 * resting place, so the input gives way instead: it drops by exactly that overrun,
 * which leaves the clearance between the two and the log where it was. Only what
 * grows ABOVE the field -- the completion list -- still lifts the log.
 *
 * Measured, not written down: the field's height is the keycaps', and those are
 * type in a translated word.
 */
export const inputDrop = computed(() => Math.max(0, field.value + CLEARANCE - RESTING_BOTTOM))
