// 车牌 3D 卡片（iOS 内嵌版）：只保留模型与状态驱动，UI 由 SwiftUI 负责

import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';

const host = document.querySelector('#canvas');
const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.toneMappingExposure = 1.05;
host.appendChild(renderer.domElement);

const scene = new THREE.Scene();

const camera = new THREE.PerspectiveCamera(36, 1, 0.1, 200);
const HOME_POS = new THREE.Vector3(-6.4, 3.2, 6.4);
const HOME_TARGET = new THREE.Vector3(0, 0.8, 0);

camera.position.copy(HOME_POS);
const controls = new OrbitControls(camera, renderer.domElement);
controls.target.copy(HOME_TARGET);
controls.enableDamping = true;
controls.dampingFactor = 0.08;
controls.minDistance = 3.5;
controls.maxDistance = 16;
controls.minPolarAngle = 0.15;
controls.maxPolarAngle = Math.PI / 2 - 0.03;
controls.enablePan = false;
controls.autoRotateSpeed = 1.2;
controls.update();

scene.add(new THREE.HemisphereLight(0xffffff, 0x4a5866, 2.1));
const sun = new THREE.DirectionalLight(0xffffff, 2.2);
sun.position.set(-5, 9, 6);
scene.add(sun);
const fill = new THREE.DirectionalLight(0x9fc2ff, 1.1);
fill.position.set(6, 4, -6);
scene.add(fill);

// 柔和接触阴影（避免模型看起来“悬空”）
const shadow = new THREE.Mesh(
  new THREE.CircleGeometry(4.2, 64),
  new THREE.MeshBasicMaterial({ color: 0x000000, transparent: true, opacity: 0.28, depthWrite: false })
);
shadow.rotation.x = -Math.PI / 2;
shadow.position.y = -0.01;
shadow.scale.set(1, 1.55, 1);
scene.add(shadow);

function resize() {
  const w = host.clientWidth || window.innerWidth;
  const h = host.clientHeight || window.innerHeight;
  if (!w || !h) return;
  camera.aspect = w / h;
  camera.updateProjectionMatrix();
  renderer.setSize(w, h, false);
}
window.addEventListener('resize', resize);
window.addEventListener('orientationchange', resize);
new ResizeObserver(resize).observe(host);
resize();

const SIDES = ['leftFront', 'rightFront', 'leftRear', 'rightRear'];
const SUFFIX = {
  leftFront: 'Left_Front',
  rightFront: 'Right_Front',
  leftRear: 'Left_Rear',
  rightRear: 'Right_Rear'
};

const movements = { windows: {}, doors: {} };
const lampActions = {};
let mixer;
let model;
let ready = false;
let previous = performance.now();

function findClip(clipName) {
  const clip = model ? model.animations.find(item => item.name === clipName) : null;
  if (!clip) throw new Error('模型缺少动画：' + clipName);
  return clip;
}

function movement(clipName, duration) {
  const action = mixer.clipAction(findClip(clipName));
  action.play();
  action.paused = true;
  action.time = 0;
  return { action, duration, value: 0, target: 0 };
}

function postReady(message) {
  try {
    window.webkit?.messageHandlers?.car3d?.postMessage(message);
  } catch (e) { /* 非 iOS 环境忽略 */ }
}

async function boot() {
  const gltf = await new GLTFLoader().loadAsync('./model/car.glb');
  model = gltf;
  scene.add(gltf.scene);
  gltf.scene.traverse(obj => {
    if (obj.isMesh) {
      obj.castShadow = false;
      obj.receiveShadow = false;
    }
  });
  mixer = new THREE.AnimationMixer(gltf.scene);

  for (const side of SIDES) {
    movements.windows[side] = movement('Window_' + SUFFIX[side] + '_Down', 1);
    movements.doors[side] = movement('Door_' + SUFFIX[side] + '_Open', 1.4);
  }
  movements.doors.tailgate = movement('Tailgate_Open', 1.4);

  const lamps = {
    running: 'Lights_On',
    brake: 'Brake_Lights_On',
    turnLeft: 'Turn_Left_Blink',
    turnRight: 'Turn_Right_Blink',
    lowBeam: 'Low_Beam_On',
    highBeam: 'High_Beam_On'
  };
  for (const [key, clipName] of Object.entries(lamps)) {
    lampActions[key] = { action: mixer.clipAction(findClip(clipName)), on: false };
  }

  ready = true;
  postReady('ready');
}

boot().catch(error => {
  console.error(error);
  postReady('error:' + (error && error.message ? error.message : error));
});

function setDoor(id, open) {
  const state = movements.doors[id];
  if (state) state.target = open ? 1 : 0;
}

function setWindow(id, down) {
  const state = movements.windows[id];
  if (state) state.target = down ? 1 : 0;
}

function setLamp(key, on) {
  const item = lampActions[key];
  if (!item) return;
  item.on = Boolean(on);
  if (item.on) {
    item.action.reset().play();
    item.action.time = 0.35;
    item.action.paused = true;
  } else {
    item.action.stop();
  }
}

window.Car3D = {
  isReady: () => ready,

  setDoor,
  setWindow,
  setTailgate: open => setDoor('tailgate', open),

  setLight(key, on) { setLamp(key, on); },

  setLights(states) {
    for (const key of Object.keys(lampActions)) setLamp(key, Boolean(states?.[key]));
  },

  /** 一次性把车辆状态推给模型 */
  applyStatus(status) {
    if (!ready || !status) return;
    const doors = status.doors || {};
    const windows = status.windows || {};
    for (const side of SIDES) {
      if (side in doors) setDoor(side, doors[side]);
      if (side in windows) setWindow(side, windows[side]);
    }
    if ('tailgate' in doors) setDoor('tailgate', doors.tailgate);
    if (status.lights) this.setLights(status.lights);
  },

  setAutoRotate(on) { controls.autoRotate = Boolean(on); },

  resetView() {
    camera.position.copy(HOME_POS);
    controls.target.copy(HOME_TARGET);
    controls.update();
  },

  /** 呼吸式开关门预览（点按钮时给个视觉反馈） */
  pulseDoor(id) {
    const state = movements.doors[id];
    if (!state) return;
    state.target = state.target > 0.5 ? 0 : 1;
  }
};

renderer.setAnimationLoop(now => {
  const dt = Math.min((now - previous) / 1000, 0.05);
  previous = now;

  if (mixer) {
    for (const group of Object.values(movements)) {
      for (const state of Object.values(group)) {
        const step = dt / state.duration;
        state.value = state.value < state.target
          ? Math.min(state.target, state.value + step)
          : Math.max(state.target, state.value - step);
        state.action.time = state.value * state.duration;
      }
    }
    mixer.update(dt);
  }

  controls.update();
  renderer.render(scene, camera);
});
