import CallHolo from '@/modules/calls/HoloRoot.vue'
import ChatInput from '@/modules/chat/ChatInput.vue'
import ChatLog from '@/modules/chat/ChatLog.vue'
import DoorlockView from '@/modules/doorlock/DoorlockView.vue'
import DownedView from '@/modules/downed/DownedView.vue'
import FormView from '@/modules/form/FormView.vue'
import HudRoot from '@/modules/hud/HudRoot.vue'
import InventoryView from '@/modules/inventory/InventoryView.vue'
import LoadingCover from '@/modules/loading/LoadingCover.vue'
import MenuView from '@/modules/menu/MenuView.vue'
import NotifyRoot from '@/modules/notify/NotifyRoot.vue'
import PanelView from '@/modules/panel/PanelView.vue'
import ProgressRoot from '@/modules/progress/ProgressRoot.vue'
import PoolHud from '@/modules/pool/PoolHud.vue'
import RadioHolo from '@/modules/radio/RadioHolo.vue'
import SlotbarRoot from '@/modules/inventory/SlotbarRoot.vue'
import PromptsRoot from '@/modules/prompts/PromptsRoot.vue'
import SpawnView from '@/modules/spawn/SpawnView.vue'
import TagsRoot from '@/modules/tags/TagsRoot.vue'
import TargetView from '@/modules/target/TargetView.vue'
import { createSurface } from './createSurface'
import { registerModule } from './registry'
import SurfaceRoot from './SurfaceRoot.vue'

/**
 * THE SURFACE -- one CEF page, two layers.
 *
 * This was two pages. One build is simpler, and the duplication it removed was not
 * small: eight woff2 faces at 158 kB byte-identical in both, plus the Vue runtime and
 * the whole design system, twice. ~400 kB of 926.
 *
 * `surface` on a registration is now a LAYER inside this page, and it still matters:
 *   overlay  the HUD. Never focused, never takes a pointer, always drawn.
 *   modal    everything the player drives. Takes focus and the cursor when open.
 *
 * `allowFocus` is true because the page as a whole can be focused; `configureFocus`
 * no longer refuses it for the HUD, so the rule that a HUD must not ask for focus is
 * now carried by the layer a module registers on rather than by the surface it lives
 * on. A HUD module calling `acquireFocus` would take the player's controls away, and
 * nothing in the code stops it -- which is the one guarantee this merge gave up.
 */
// `hideWhileLoading` IS EVERYTHING DRAWN OVER LIVE PLAY. The game's own loading screen
// is up for a teleport, a lift ride and a respawn, and every one of these went on
// drawing over it as if the player were still in the street they had just left: the
// gauges, the key strip that had said "take the lift", the toasts, the tags. While
// `modules/loading` says a load is up they are taken off screen and kept mounted, and
// each comes back exactly as its own module last left it.
registerModule({ id: 'hud', surface: 'overlay', component: HudRoot, hideWhileLoading: true })
// Toasts on a layer of their own ABOVE the modal one: most of them answer something the
// player just did on a modal view, and under it they were dimmed by that view's scrim.
registerModule({ id: 'notify', surface: 'notice', component: NotifyRoot, hideWhileLoading: true })
registerModule({ id: 'prompts', surface: 'overlay', component: PromptsRoot, hideWhileLoading: true })
registerModule({ id: 'progress', surface: 'overlay', component: ProgressRoot, hideWhileLoading: true })
registerModule({ id: 'pool', surface: 'overlay', component: PoolHud, hideWhileLoading: true })

// THE INVENTORY IS TWO REGISTRATIONS for the same reason the chat is: two
// concerns on two layers. `InventoryView` below is the bag the player drives and
// takes focus; this is the few-second peek at the hotbar row, which is drawn
// over whatever the player is aiming at and must never take a pointer.
registerModule({
  id: 'inventory-slotbar',
  surface: 'overlay',
  component: SlotbarRoot,
  hideWhileLoading: true
})

// Name tags draw over bodies in the world, so they are on the overlay and must
// never take focus: one that captured the keyboard would stop the player moving.
registerModule({ id: 'tags', surface: 'overlay', component: TagsRoot, hideWhileLoading: true })

// THE HOLOCALL IS ONE SCREEN. The card and the live chip that used to sit on the
// left are gone on the owner's word; the sphere below says who is calling, who
// you are talking to and which key answers or hangs up. It takes focus only when
// the player opens it on its key.
registerModule({ id: 'calls-holo', surface: 'modal', component: CallHolo, hideWhileLoading: true })

// THE RADIO IS A HANDSET, not a menu -- "un vrais style de radio mais holograpique qui
// pop a droite de l'ecran". Modal because it is pressed; it takes focus only while the
// player has it out.
registerModule({ id: 'radio-holo', surface: 'modal', component: RadioHolo, hideWhileLoading: true })

// The chat is ONE Lua module drawn as TWO registrations, because it is two
// concerns on two layers: the log is always drawn and never focused, the input
// line takes the keyboard. Lua already treats them as two views -- every payload
// it publishes names the layer it belongs to -- so this is the split it expects,
// not one imposed here.
registerModule({ id: 'chat-log', surface: 'overlay', component: ChatLog, hideWhileLoading: true })
registerModule({ id: 'chat-input', surface: 'modal', component: ChatInput })

registerModule({ id: 'inventory', surface: 'modal', component: InventoryView })
registerModule({ id: 'menu', surface: 'modal', component: MenuView })
registerModule({ id: 'form', surface: 'modal', component: FormView })
registerModule({ id: 'panel', surface: 'modal', component: PanelView })
// ox_doorlock's staff panel, a view of its own rather than a menu or a panel spec: a
// table with search and pages and a tabbed settings form are more than either contract
// draws. On `modal` for the cursor; it hides itself (and gives the focus back) while the
// staff member aims at a door for "Pick in world". See `modules/doorlock/client/panel.lua`.
registerModule({ id: 'doorlock', surface: 'modal', component: DoorlockView })
// The eye is on `modal` for its pointer, and HUD-like for the loading hide: its rows are
// about the body or the door it landed on, and neither is there over a loading screen.
registerModule({ id: 'target', surface: 'modal', component: TargetView, hideWhileLoading: true })

// The one screen a player is given rather than offered: a brand new character has no
// position, so where it starts is a question the server must have an answer to. It is
// on `modal` for the cursor, not for the style -- a spawn list nobody can click is the
// same as no choice at all.
registerModule({ id: 'spawn', surface: 'modal', component: SpawnView })

// The other screen a player is given rather than offered, and the one that MUST be
// `modal`: it is two controls, one of them held down for a second and a half, and the
// overlay layer is `pointer-events: none` for its whole height -- a death screen
// registered there would draw perfectly and refuse every press.
registerModule({ id: 'downed', surface: 'modal', component: DownedView })

// THE LOADING COVER, on a layer of its own above all the others: it is drawn over the
// game's own loading screen during a load in play, and over everything this page has.
// Never a pointer -- a load is nothing the player drives.
registerModule({ id: 'loading', surface: 'cover', component: LoadingCover })

createSurface({
  name: 'ui',
  root: SurfaceRoot,
  rootProps: {},
  allowFocus: true
})
