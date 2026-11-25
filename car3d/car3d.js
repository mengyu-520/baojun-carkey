// 车辆 3D 卡片（iOS 内嵌版，classic script 版本）
// 依赖：vendor/three.min.js、vendor/GLTFLoader.js、vendor/OrbitControls.js、model-data.js

(function () {
  'use strict';

  var stage = function (text) {
    try { if (window.__stage) window.__stage(text); } catch (e) {}
  };
  stage('car3d-start');

  if (typeof THREE === 'undefined') {
    stage('error: three.js 未加载');
    return;
  }
  stage('three-ok r' + THREE.REVISION);

  var host = document.querySelector('#canvas');
  var renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
  renderer.outputEncoding = THREE.sRGBEncoding;
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.toneMappingExposure = 1.0;
  host.appendChild(renderer.domElement);
  renderer.domElement.style.display = 'block';
  renderer.domElement.style.width = '100%';
  renderer.domElement.style.height = '100%';

  var scene = new THREE.Scene();
  var camera = new THREE.PerspectiveCamera(36, 1, 0.1, 200);
  var HOME_POS = new THREE.Vector3(-6.4, 3.2, 6.4);
  var HOME_TARGET = new THREE.Vector3(0, 0.8, 0);

  camera.position.copy(HOME_POS);
  var controls = new THREE.OrbitControls(camera, renderer.domElement);
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

  scene.add(new THREE.HemisphereLight(0xffffff, 0x4a5866, 0.95));
  var sun = new THREE.DirectionalLight(0xffffff, 1.15);
  sun.position.set(-5, 9, 6);
  scene.add(sun);
  var fill = new THREE.DirectionalLight(0x9fc2ff, 0.55);
  fill.position.set(6, 4, -6);
  scene.add(fill);

  var shadow = new THREE.Mesh(
    new THREE.CircleGeometry(4.2, 48),
    new THREE.MeshBasicMaterial({ color: 0x000000, transparent: true, opacity: 0.26, depthWrite: false })
  );
  shadow.rotation.x = -Math.PI / 2;
  shadow.position.y = -0.01;
  shadow.scale.set(1, 1.55, 1);
  scene.add(shadow);

  function resize() {
    var w = host.clientWidth || window.innerWidth;
    var h = host.clientHeight || window.innerHeight;
    if (!w || !h) return;
    camera.aspect = w / h;
    camera.updateProjectionMatrix();
    renderer.setSize(w, h, true);
    renderer.domElement.style.width = '100%';
    renderer.domElement.style.height = '100%';
    applyCameraFit();
  }
  window.addEventListener('resize', resize);
  window.addEventListener('orientationchange', resize);
  if (window.ResizeObserver) new ResizeObserver(resize).observe(host);
  resize();

  var SIDES = ['leftFront', 'rightFront', 'leftRear', 'rightRear'];
  var SUFFIX = {
    leftFront: 'Left_Front',
    rightFront: 'Right_Front',
    leftRear: 'Left_Rear',
    rightRear: 'Right_Rear'
  };

  var movements = { windows: {}, doors: {} };
  var lampActions = {};
  var mixer = null;
  var gltfRoot = null;
  var animations = [];
  var ready = false;
  var previous = performance.now();

  function findClip(name) {
    for (var i = 0; i < animations.length; i++) {
      if (animations[i].name === name) return animations[i];
    }
    return null;
  }

  function movement(clipName, duration) {
    var clip = findClip(clipName);
    if (!clip) return null;
    var action = mixer.clipAction(clip);
    action.play();
    action.paused = true;
    action.time = 0;
    return { action: action, duration: duration, value: 0, target: 0 };
  }

  function post(message) {
    try { window.webkit.messageHandlers.car3d.postMessage(message); } catch (e) {}
  }

  function b64ToArrayBuffer(b64) {
    var bin = window.atob(b64);
    var len = bin.length;
    var buffer = new ArrayBuffer(len);
    var bytes = new Uint8Array(buffer);
    for (var i = 0; i < len; i++) bytes[i] = bin.charCodeAt(i);
    return buffer;
  }

  // 模型尺寸归一化 + 自动取景：全车必须完整落在卡片视窗内（横竖屏都算过）
  var modelRadius = 0;
  var modelHeight = 0;

  function meshBox(root) {
    root.updateMatrixWorld(true);
    var box = new THREE.Box3();
    var tmp = new THREE.Box3();
    root.traverse(function (node) {
      if (!node.isMesh || node.visible === false || !node.geometry) return;
      if (!node.geometry.boundingBox) node.geometry.computeBoundingBox();
      if (!node.geometry.boundingBox) return;
      tmp.copy(node.geometry.boundingBox).applyMatrix4(node.matrixWorld);
      box.union(tmp);
    });
    return box;
  }

  function fitModel(root) {
    var box = meshBox(root);
    if (box.isEmpty()) box = new THREE.Box3().setFromObject(root);
    var size = box.getSize(new THREE.Vector3());
    var center = box.getCenter(new THREE.Vector3());
    var maxDim = Math.max(size.x, size.z) || 1;
    var scale = 6.4 / maxDim;

    root.scale.setScalar(scale);
    root.position.set(-center.x * scale, -box.min.y * scale, -center.z * scale);

    var box2 = meshBox(root);
    var size2 = box2.getSize(new THREE.Vector3());
    modelRadius = 0.5 * Math.sqrt(size2.x * size2.x + size2.y * size2.y + size2.z * size2.z);
    modelHeight = size2.y;

    shadow.geometry.dispose();
    shadow.geometry = new THREE.CircleGeometry(modelRadius * 0.72, 48);
    shadow.position.y = 0;
    shadow.scale.set(1, 1, 1);

    applyCameraFit();

    if (window.location.search.indexOf('debug') >= 0) {
      var el = document.getElementById('diag');
      if (el) {
        el.style.display = 'block';
        el.style.color = '#0ff';
        var c2 = box2.getCenter(new THREE.Vector3());
        el.textContent = 'center=' + c2.x.toFixed(2) + '/' + c2.y.toFixed(2) + '/' + c2.z.toFixed(2)
          + ' size=' + size2.x.toFixed(2) + '/' + size2.y.toFixed(2) + '/' + size2.z.toFixed(2)
          + ' r=' + modelRadius.toFixed(2)
          + ' cam=' + camera.position.toArray().map(function (v) { return v.toFixed(1); }).join(',')
          + ' asp=' + camera.aspect.toFixed(2);
      }
    }
  }

  // 取景：同时满足垂直和水平视野，留 18% 余量，视角固定为前侧上方 3/4 角
  function applyCameraFit() {
    if (!modelRadius) return;

    var vFov = camera.fov * Math.PI / 180;
    var hFov = 2 * Math.atan(Math.tan(vFov / 2) * Math.max(camera.aspect, 0.01));
    var horizontalNeed = modelRadius / Math.sin(hFov / 2);
    var verticalNeed = modelRadius / Math.sin(vFov / 2);
    var distance = Math.max(horizontalNeed, verticalNeed) * 1.22;

    var dir = new THREE.Vector3(-0.62, 0.40, 0.66).normalize();
    var target = new THREE.Vector3(0, modelHeight * 0.44, 0);

    HOME_TARGET.copy(target);
    HOME_POS.copy(target).addScaledVector(dir, distance);

    camera.position.copy(HOME_POS);
    controls.target.copy(HOME_TARGET);
    controls.minDistance = modelRadius * 0.9;
    controls.maxDistance = Math.max(distance * 1.8, modelRadius * 4);
    controls.update();
  }

  function boot() {
    if (!window.CAR_GLB_BASE64) {
      stage('error: 模型数据缺失');
      return;
    }
    stage('decoding-model');
    var buffer = b64ToArrayBuffer(window.CAR_GLB_BASE64);

    var loader = new THREE.GLTFLoader();
    loader.parse(buffer, '', function (gltf) {
      // 用一层 wrapper 承载缩放/居中，避免模型的动画轨道改写 root 自身变换
      var inner = gltf.scene;
      // 灯光投射到地面的贴片在卡片里会变成一块脏影，直接隐藏
      inner.traverse(function (node) {
        if (node.name && /Ground_Visual/i.test(node.name)) node.visible = false;
      });
      gltfRoot = new THREE.Group();
      gltfRoot.add(inner);
      animations = gltf.animations || [];
      scene.add(gltfRoot);
      fitModel(gltfRoot);
      mixer = new THREE.AnimationMixer(inner);

      for (var i = 0; i < SIDES.length; i++) {
        var side = SIDES[i];
        movements.windows[side] = movement('Window_' + SUFFIX[side] + '_Down', 1);
        movements.doors[side] = movement('Door_' + SUFFIX[side] + '_Open', 1.4);
      }
      movements.doors.tailgate = movement('Tailgate_Open', 1.4);

      var lamps = {
        running: 'Lights_On',
        brake: 'Brake_Lights_On',
        turnLeft: 'Turn_Left_Blink',
        turnRight: 'Turn_Right_Blink',
        lowBeam: 'Low_Beam_On',
        highBeam: 'High_Beam_On'
      };
      for (var key in lamps) {
        var clip = findClip(lamps[key]);
        if (clip) lampActions[key] = { action: mixer.clipAction(clip), on: false };
      }

      ready = true;
      stage('model-ready clips=' + animations.length);
      post('ready');

      if (window.location.search.indexOf('demo') >= 0) {
        setTimeout(function () {
          window.Car3D.applyStatus({
            doors: { leftFront: true, rightRear: true, tailgate: true },
            windows: { leftFront: true, rightFront: true },
            lights: { running: true }
          });
        }, 400);
      }
    }, function (error) {
      stage('error: ' + (error && error.message ? error.message : error));
    });
  }

  function setDoor(id, open) {
    var state = movements.doors[id];
    if (state) state.target = open ? 1 : 0;
  }

  function setWindow(id, down) {
    var state = movements.windows[id];
    if (state) state.target = down ? 1 : 0;
  }

  function setLamp(key, on) {
    var item = lampActions[key];
    if (!item) return;
    item.on = !!on;
    if (item.on) {
      item.action.reset().play();
      item.action.time = 0.35;
      item.action.paused = true;
    } else {
      item.action.stop();
    }
  }

  window.Car3D = {
    isReady: function () { return ready; },

    setDoor: setDoor,
    setWindow: setWindow,
    setTailgate: function (open) { setDoor('tailgate', open); },
    setLight: function (key, on) { setLamp(key, on); },

    applyStatus: function (status) {
      if (!ready || !status) return;
      var doors = status.doors || {};
      var windows = status.windows || {};
      for (var i = 0; i < SIDES.length; i++) {
        var side = SIDES[i];
        if (side in doors) setDoor(side, doors[side]);
        if (side in windows) setWindow(side, windows[side]);
      }
      if ('tailgate' in doors) setDoor('tailgate', doors.tailgate);
      if (status.lights) {
        for (var key in lampActions) setLamp(key, !!status.lights[key]);
      }
    },

    setAutoRotate: function (on) { controls.autoRotate = !!on; },

    resetView: function () {
      camera.position.copy(HOME_POS);
      controls.target.copy(HOME_TARGET);
      controls.update();
    },

    pulseDoor: function (id) {
      var state = movements.doors[id];
      if (!state) return;
      state.target = state.target > 0.5 ? 0 : 1;
    }
  };

  window.addEventListener('load', boot);

  renderer.setAnimationLoop(function (now) {
    var dt = Math.min((now - previous) / 1000, 0.05);
    previous = now;

    if (mixer) {
      for (var groupName in movements) {
        var group = movements[groupName];
        for (var id in group) {
          var state = group[id];
          if (!state) continue;
          var step = dt / state.duration;
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
})();
