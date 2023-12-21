# ReviewTools.jl

Track missing reviews for JuliaCon.

To use it set your Pretalx token:
```julia
using ReviewTools
set_pretalx_token!("my token")
```

Then run `main()` to start an infinite loop regenerating the `missing_reviews.html`.
```julia
import ReviewTools
ReviewTools.main()
```
