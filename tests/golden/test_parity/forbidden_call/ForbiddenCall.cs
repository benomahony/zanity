using System.Threading.Tasks;
using Microsoft.CodeAnalysis.CSharp.Scripting;

class ForbiddenCall
{
    Task<object> Run(string code)
    {
        return CSharpScript.EvaluateAsync(code);
    }

    int Parse(string text)
    {
        return int.Parse(text);
    }
}
