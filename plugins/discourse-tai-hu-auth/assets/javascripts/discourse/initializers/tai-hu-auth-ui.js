import { withPluginApi } from "discourse/lib/plugin-api";

const TAI_HU_RELOAD_KEY = "tai_hu_auth_reload_count";
const MAX_RELOAD_COUNT = 3;

export default {
  name: "tai-hu-auth-ui",

  initialize() {
    withPluginApi((api) => {
      const currentUser = api.getCurrentUser();

      if (currentUser) {
        // 用户已登录，清除刷新计数器
        sessionStorage.removeItem(TAI_HU_RELOAD_KEY);
        return;
      }

      // 用户未登录，检查是否需要自动刷新
      // 这是为了解决首次登录后页面状态不同步的问题
      // 后端已经设置了 Cookie，但前端预加载数据中没有用户信息
      this._autoReloadIfNeeded();

      // 隐藏登录按钮（太湖认证是前置的，用户无需手动登录）
      const headerService = api.container.lookup("service:header");
      if (headerService) {
        const hider = { name: "tai-hu-auth" };
        headerService.registerHider(hider, ["login", "signup"]);
      }
    });
  },

  _autoReloadIfNeeded() {
    // 获取当前刷新次数
    let reloadCount = parseInt(
      sessionStorage.getItem(TAI_HU_RELOAD_KEY) || "0",
      10
    );

    // 如果已经刷新了 MAX_RELOAD_COUNT 次，不再刷新
    if (reloadCount >= MAX_RELOAD_COUNT) {
      // eslint-disable-next-line no-console
      console.log(`[太湖认证] 已刷新 ${reloadCount} 次，停止自动刷新`);
      // 清除计数器，避免影响后续访问
      sessionStorage.removeItem(TAI_HU_RELOAD_KEY);
      return;
    }

    // 检查是否有 _t cookie（表示后端已经登录成功）
    const hasTCookie = document.cookie
      .split(";")
      .some((c) => c.trim().startsWith("_t="));

    if (hasTCookie) {
      // 有 Cookie 但前端没有用户信息，说明需要刷新
      reloadCount++;
      sessionStorage.setItem(TAI_HU_RELOAD_KEY, reloadCount.toString());
      // eslint-disable-next-line no-console
      console.log(
        `[太湖认证] 检测到登录态不同步，第 ${reloadCount} 次刷新页面...`
      );

      // 延迟一点刷新，确保 sessionStorage 已保存
      setTimeout(() => {
        window.location.reload();
      }, 100);
    }
  },
};
