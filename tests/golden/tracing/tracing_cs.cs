using System.Diagnostics;

class Orders
{
    private Activity current;

    void Forgotten(ActivitySource source)
    {
        Activity activity = source.StartActivity("forgotten");
        activity.SetTag("order", 1);
    }

    void Stopped(ActivitySource source)
    {
        Activity activity = source.StartActivity("stopped");
        activity.Stop();
    }

    void Disposed(ActivitySource source)
    {
        using var activity = source.StartActivity("disposed");
        using (var other = source.StartActivity("other"))
        {
        }
    }

    Activity Returned(ActivitySource source)
    {
        return source.StartActivity("returned");
    }

    void Stored(ActivitySource source)
    {
        Activity activity = source.StartActivity("stored");
        this.current = activity;
    }

    void Named(ActivitySource source, string id)
    {
        using var activity = source.StartActivity($"order {id}");
    }
}
