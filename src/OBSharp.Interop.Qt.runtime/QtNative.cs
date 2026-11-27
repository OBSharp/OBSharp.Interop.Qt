using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.Marshalling;

namespace OBSharp.Interop.Qt;

/// <summary>
/// Qt 绑定在托管侧缺少的几个便利入口：构造 <c>QString</c>、把句柄取成原生指针、释放信号连接。
/// </summary>
/// <remarks>
/// <list type="bullet">
/// <item>生成器不为 <c>QString</c> 生成 <c>QString::fromUtf8</c>，也没有接托管 <see cref="string"/> 的重载；
/// 但 <c>const QString&amp;</c> 形参在 C 侧直接收 UTF-8 借用指针（<c>nint</c>），
/// 所以设置文本时用 <see cref="CreateUtf8"/> 即可，不需要先搭一个 <c>QString</c> 对象。</item>
/// <item><c>QFlags&lt;T&gt;</c> 形参在 C 侧一律是 <c>int32_t</c>，直接传整数：原生侧就地构造
/// <c>QFlags&lt;T&gt;(value)</c>，不存在任何指针解引用，因此也不会因“没法安全构造 QFlags”而崩溃。</item>
/// <item><c>qt_shim_disconnect</c> 原生侧有导出，生成器没给它生成门面，这里补一个声明。</item>
/// </list>
/// </remarks>
public static unsafe partial class QtNative
{
    /// <summary>
    /// 生成器没有为 <c>qt_shim_disconnect</c> 产出托管声明，这里补一个。
    /// </summary>
    [LibraryImport("OBSharp.Interop.Qt.Native")]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    private static partial void qt_shim_disconnect(QtShimConnection* handle);

    /// <summary>
    /// 构造承载 <paramref name="text"/> 的 <c>QString</c> 句柄。
    /// </summary>
    /// <param name="text">任意托管文本（含中文、emoji 等任意 UTF-16/代理对）。</param>
    /// <returns>新的 <c>QString</c> 句柄，由调用方释放。</returns>
    /// <remarks>
    /// 只在需要把一个 <c>QString</c> 交给 <c>QString*</c> 形参时使用；<c>const QString&amp;</c> 形参
    /// （绝大多数 setter）直接收 UTF-8，见 <see cref="CreateUtf8"/>。
    /// 逐 UTF-16 码元拼装，代理对因此天然保留（emoji 会原样出现在 QString 里）。
    /// </remarks>
    public static CppShimQString CreateString(string text)
    {
        // QString 的默认构造没有被绑定；用 QString(QStringView) 构造一个空视图，
        // 得到合法的空 QString（原生侧就是 new QString(QStringView{})）。
        CppShimQString result = CppShimQString.NewO(CppShimQStringView.Create());

        foreach (char unit in text)
        {
            // QChar(uint8_t, uint8_t) 是 QChar(uchar) 的「高字节 / 低字节」形式，两句拼出一个 UTF-16 码元。
            using CppShimQChar current = new((byte)(unit >> 8), (byte)unit);
            result.PushBackO(current);
        }

        return result;
    }

    /// <summary>
    /// 把托管文本临时编码成 UTF-8，取到内容指针供 <c>const QString&amp;</c> 形参（C 侧 <c>nint</c>）使用。
    /// </summary>
    /// <param name="text">任意托管文本；<see langword="null"/> 返回 0（原生侧视作空串）。</param>
    /// <returns>指向 NUL 结尾 UTF-8 内容的指针。</returns>
    /// <remarks>
    /// 借用语义：指针只在本次原生调用期间有效，不得跨越调用保存。
    /// 用法：<c>label.SetTextR(QtNative.CreateUtf8("你好🎉"))</c>。
    /// </remarks>
    public static nint CreateUtf8(string? text)
    {
        if (text is null)
            return 0;

        return Marshal.StringToCoTaskMemUTF8(text);
    }

    /// <summary>
    /// 释放 <see cref="CreateUtf8"/> 分配的 UTF-8 缓冲区。
    /// </summary>
    public static void FreeUtf8(nint buffer)
    {
        if (buffer is 0)
            return;

        Marshal.FreeCoTaskMem(buffer);
    }

    /// <summary>
    /// 取句柄的原生值；<see langword="null"/> 或无效句柄返回 0。
    /// </summary>
    /// <param name="handle">任意 Qt 句柄。</param>
    /// <returns>可传给 <c>void*</c> 形参的原生指针。</returns>
    public static nint ToPointer(SafeHandle? handle)
        => handle is null || handle.IsInvalid ? 0 : handle.DangerousGetHandle();

    /// <summary>
    /// 断开并释放一条信号连接。
    /// </summary>
    /// <param name="connection">由 <c>*ConnectXxx</c> 返回的指针。</param>
    public static void Disconnect(QtShimConnection* connection)
    {
        if (connection is not null)
            qt_shim_disconnect(connection);
    }
}
