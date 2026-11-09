const previews = {
  guarding: {
    image: "/assets/guarding.jpg",
    alt: "Mac 哨兵守卫界面：青色机械眼与扫描光带，底部保留系统解锁区域",
    status: "守卫已就位",
  },
  warning: {
    image: "/assets/warning.jpg",
    alt: "Mac 哨兵告警界面：红蓝警灯、摄像头占位区域与驱离提示；此预览不包含真实摄像头画面",
    status: "人脸确认，切换警示",
  },
};

// 切换真实应用的静态预览，始终不申请浏览器摄像头或播放声音，喵~
function selectPreview(mode) {
  const preview = previews[mode];
  if (!preview) return;
  const image = document.getElementById("demo-image");
  image.src = preview.image;
  image.alt = preview.alt;
  document.getElementById("demo-status").textContent = preview.status;
  document.querySelectorAll("[data-mode]").forEach((button) => {
    const active = button.dataset.mode === mode;
    button.classList.toggle("active", active);
    button.setAttribute("aria-pressed", String(active));
  });
}

document.querySelectorAll("[data-mode]").forEach((button) => {
  button.addEventListener("click", () => selectPreview(button.dataset.mode));
});

if (window.location.origin === "https://mac-sentry.vercel.app") {
  const measurementId = "G-1B61MR7V7V";
  window.dataLayer = window.dataLayer || [];

  // 在 Google 标签加载前排队记录官网访问，喵~
  window.gtag = function gtag() {
    window.dataLayer.push(arguments);
  };
  window.gtag("js", new Date());
  window.gtag("config", measurementId, {
    allow_google_signals: false,
    allow_ad_personalization_signals: false,
  });

  const analyticsScript = document.createElement("script");
  analyticsScript.async = true;
  analyticsScript.src = `https://www.googletagmanager.com/gtag/js?id=${measurementId}`;
  document.head.append(analyticsScript);
}
