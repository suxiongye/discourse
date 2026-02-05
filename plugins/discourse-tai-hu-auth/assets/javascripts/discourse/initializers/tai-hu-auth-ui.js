import { withPluginApi } from "discourse/lib/plugin-api";
import PreloadStore from "discourse/lib/preload-store";

const TAI_HU_RELOAD_KEY = "tai_hu_auth_reload_count";
const MAX_RELOAD_COUNT = 3;

// 调试日志前缀
const LOG_PREFIX = "[太湖认证-前端]";

export default {
  name: "tai-hu-auth-ui",

  initialize() {
    // ========== 调试信息开始 ==========
    // eslint-disable-next-line no-console
    console.log(`${LOG_PREFIX} ========== 初始化开始 ==========`);
    
    // 检查 PreloadStore 中的数据
    const preloadedCurrentUser = PreloadStore.get("currentUser");
    // eslint-disable-next-line no-console
    console.log(`${LOG_PREFIX} PreloadStore.get("currentUser"):`, preloadedCurrentUser);
    
    // 检查 data-preloaded 元素
    const preloadedDataElement = document.getElementById("data-preloaded");
    if (preloadedDataElement) {
      try {
        const preloaded = JSON.parse(preloadedDataElement.dataset.preloaded);
        const hasCurrentUser = "currentUser" in preloaded;
        // eslint-disable-next-line no-console
        console.log(`${LOG_PREFIX} #data-preloaded 包含 currentUser:`, hasCurrentUser);
        if (hasCurrentUser) {
          const currentUserData = JSON.parse(preloaded.currentUser);
          // eslint-disable-next-line no-console
          console.log(`${LOG_PREFIX} #data-preloaded currentUser 数据:`, {
            id: currentUserData?.id,
            username: currentUserData?.username,
            name: currentUserData?.name,
          });
        }
      } catch (e) {
        // eslint-disable-next-line no-console
        console.error(`${LOG_PREFIX} 解析 #data-preloaded 失败:`, e);
      }
    } else {
      // eslint-disable-next-line no-console
      console.log(`${LOG_PREFIX} #data-preloaded 元素不存在`);
    }
    
    // 检查 Cookie
    const cookies = document.cookie.split(";").map(c => c.trim());
    const tCookie = cookies.find(c => c.startsWith("_t="));
    // eslint-disable-next-line no-console
    console.log(`${LOG_PREFIX} _t Cookie 存在:`, !!tCookie);
    // eslint-disable-next-line no-console
    console.log(`${LOG_PREFIX} 所有 Cookie 名称:`, cookies.map(c => c.split("=")[0]));
    // ========== 调试信息结束 ==========

    withPluginApi((api) => {
      const currentUser = api.getCurrentUser();
      
      // eslint-disable-next-line no-console
      console.log(`${LOG_PREFIX} api.getCurrentUser():`, currentUser ? {
        id: currentUser.id,
        username: currentUser.username,
        name: currentUser.name,
      } : null);

      if (currentUser) {
        // 用户已登录，清除刷新计数器
        sessionStorage.removeItem(TAI_HU_RELOAD_KEY);
        // eslint-disable-next-line no-console
        console.log(`${LOG_PREFIX} ✅ 用户已登录，初始化完成`);
        // eslint-disable-next-line no-console
        console.log(`${LOG_PREFIX} ========== 初始化结束 ==========`);
        return;
      }

      // eslint-disable-next-line no-console
      console.log(`${LOG_PREFIX} ⚠️ currentUser 为空，检查是否需要刷新...`);

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
      
      // eslint-disable-next-line no-console
      console.log(`${LOG_PREFIX} ========== 初始化结束 ==========`);
    });
  },

  _autoReloadIfNeeded() {
    // 获取当前刷新次数
    let reloadCount = parseInt(
      sessionStorage.getItem(TAI_HU_RELOAD_KEY) || "0",
      10
    );

    // eslint-disable-next-line no-console
    console.log(`${LOG_PREFIX} 当前刷新次数:`, reloadCount);

    // 如果已经刷新了 MAX_RELOAD_COUNT 次，不再刷新
    if (reloadCount >= MAX_RELOAD_COUNT) {
      // eslint-disable-next-line no-console
      console.log(`${LOG_PREFIX} ❌ 已刷新 ${reloadCount} 次，停止自动刷新`);
      // 清除计数器，避免影响后续访问
      sessionStorage.removeItem(TAI_HU_RELOAD_KEY);
      return;
    }

    // 检查是否有 _t cookie（表示后端已经登录成功）
    const hasTCookie = document.cookie
      .split(";")
      .some((c) => c.trim().startsWith("_t="));

    // eslint-disable-next-line no-console
    console.log(`${LOG_PREFIX} 检测到 _t Cookie:`, hasTCookie);

    if (hasTCookie) {
      // 有 Cookie 但前端没有用户信息，说明需要刷新
      reloadCount++;
      sessionStorage.setItem(TAI_HU_RELOAD_KEY, reloadCount.toString());
      // eslint-disable-next-line no-console
      console.log(
        `${LOG_PREFIX} 🔄 检测到登录态不同步（有 Cookie 但无 currentUser），第 ${reloadCount} 次刷新页面...`
      );

      // 延迟一点刷新，确保 sessionStorage 已保存
      setTimeout(() => {
        window.location.reload();
      }, 100);
    } else {
      // eslint-disable-next-line no-console
      console.log(`${LOG_PREFIX} 无 _t Cookie，用户确实未登录`);
    }
  },
};
